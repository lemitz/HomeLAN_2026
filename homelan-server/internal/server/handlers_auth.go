package server

import (
	"crypto/subtle"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"time"

	"golang.org/x/crypto/bcrypt"
	"homelan-server/internal/db"
	"homelan-server/internal/models"
	"homelan-server/internal/panic"
)

type userView struct {
	ID        int64  `json:"id"`
	Username  string `json:"username"`
	IsAdmin   bool   `json:"is_admin"`
	PublicKey []byte `json:"public_key"`
}

func viewUser(u *models.User) *userView {
	if u == nil {
		return nil
	}
	return &userView{ID: u.ID, Username: u.Username, IsAdmin: u.IsAdmin, PublicKey: u.PublicKey}
}

// sessionResponse — общий ответ на регистрацию, вход, привязку и проверку сессии.
func (s *Server) sessionResponse(user *models.User, deviceID, token string) (map[string]any, error) {
	partner, err := s.db.GetPartner(user.ID)
	if err != nil {
		return nil, err
	}
	resp := map[string]any{
		"user":        viewUser(user),
		"device_id":   deviceID,
		"partner":     viewUser(partner),
		"server_time": time.Now().Unix(),
	}
	if token != "" {
		resp["token"] = token
	}
	return resp, nil
}

func (s *Server) rateLimited(w http.ResponseWriter, r *http.Request) bool {
	if ok, wait := s.authRL.Allow(clientIP(r)); !ok {
		w.Header().Set("Retry-After", strconv.Itoa(int(wait.Seconds())+1))
		writeError(w, &apiError{http.StatusTooManyRequests, "rate_limited",
			fmt.Sprintf("too many attempts, retry in %d s", int(wait.Seconds())+1)})
		return true
	}
	return false
}

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	if s.rateLimited(w, r) {
		return
	}
	var req struct {
		Username   string `json:"username"`
		Password   string `json:"password"`
		DeviceID   string `json:"device_id"`
		DeviceName string `json:"device_name"`
		DeviceType string `json:"device_type"`
		PublicKey  []byte `json:"public_key"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, err)
		return
	}
	if err := validateUsername(req.Username); err != nil {
		writeError(w, err)
		return
	}
	if err := validatePassword(req.Password); err != nil {
		writeError(w, err)
		return
	}
	name, err := validateDevice(req.DeviceID, req.DeviceName, req.DeviceType)
	if err != nil {
		writeError(w, err)
		return
	}
	if err := validatePublicKey(req.PublicKey); err != nil {
		writeError(w, err)
		return
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		writeError(w, err)
		return
	}
	user, device, err := s.db.RegisterUser(db.RegisterParams{
		Username:     req.Username,
		PasswordHash: string(hash),
		PublicKey:    req.PublicKey,
		DeviceID:     req.DeviceID,
		DeviceName:   name,
		DeviceType:   req.DeviceType,
		MaxUsers:     s.cfg.Security.MaxUsers,
	})
	switch {
	case errors.Is(err, db.ErrUserLimit):
		s.authRL.Fail(clientIP(r))
		writeError(w, &apiError{http.StatusForbidden, "user_limit", "maximum number of users reached"})
		return
	case errors.Is(err, db.ErrUsernameTaken):
		writeError(w, &apiError{http.StatusConflict, "username_taken", "username already exists"})
		return
	case errors.Is(err, db.ErrDeviceExists):
		writeError(w, &apiError{http.StatusConflict, "device_exists", "device already registered"})
		return
	case err != nil:
		writeError(w, err)
		return
	}

	token, err := s.newSession(user.ID, device.DeviceID)
	if err != nil {
		writeError(w, err)
		return
	}
	resp, err := s.sessionResponse(user, device.DeviceID, token)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, resp)
	log.Printf("✅ User registered: %s (admin: %v)", user.Username, user.IsAdmin)
}

// handleLogin — вход по паролю. Разрешён только с уже привязанного к
// пользователю устройства: новые устройства добавляются через linking,
// потому что им нужен identity-ключ.
func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if s.rateLimited(w, r) {
		return
	}
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
		DeviceID string `json:"device_id"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, err)
		return
	}
	ip := clientIP(r)

	if d := s.cfg.Security.DuressPassword; d != "" &&
		subtle.ConstantTimeCompare([]byte(req.Password), []byte(d)) == 1 {
		log.Printf("🚨 Duress password entered")
		go func() {
			time.Sleep(500 * time.Millisecond)
			s.panic.Trigger(panic.ReasonDuress)
		}()
		bcrypt.CompareHashAndPassword(s.dummyHash, []byte(req.Password)) // одинаковое время ответа
		writeError(w, errInvalidCredentials)
		return
	}

	user, err := s.db.GetUserByUsername(req.Username)
	if err != nil {
		writeError(w, err)
		return
	}
	hash := s.dummyHash
	if user != nil {
		hash = []byte(user.PasswordHash)
	}
	if bcrypt.CompareHashAndPassword(hash, []byte(req.Password)) != nil || user == nil {
		s.authRL.Fail(ip)
		writeError(w, errInvalidCredentials)
		return
	}

	device, err := s.db.GetDevice(req.DeviceID)
	if err != nil {
		writeError(w, err)
		return
	}
	if device == nil || device.UserID != user.ID {
		writeError(w, &apiError{http.StatusForbidden, "device_not_linked",
			"this device is not linked to the account; link it from an existing device"})
		return
	}
	if device.IsRevoked {
		writeError(w, &apiError{http.StatusForbidden, "device_revoked", "this device has been revoked"})
		return
	}
	s.authRL.Success(ip)

	token, err := s.newSession(user.ID, device.DeviceID)
	if err != nil {
		writeError(w, err)
		return
	}
	s.db.TouchUser(user.ID)
	s.db.TouchDevice(device.DeviceID)
	resp, err := s.sessionResponse(user, device.DeviceID, token)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, resp)
	log.Printf("✅ User logged in: %s (device %s)", user.Username, device.DeviceID)
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	sess := sessionFrom(r)
	if err := s.db.RevokeSession(sess.TokenHash); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"success": true})
}

// handleSession — проверка сессии при старте клиента.
func (s *Server) handleSession(w http.ResponseWriter, r *http.Request) {
	sess := sessionFrom(r)
	user, err := s.db.GetUserByID(sess.UserID)
	if err != nil || user == nil {
		writeError(w, errUnauthorized)
		return
	}
	resp, err := s.sessionResponse(user, sess.DeviceID, "")
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handlePartner(w http.ResponseWriter, r *http.Request) {
	partner, err := s.db.GetPartner(sessionFrom(r).UserID)
	if err != nil {
		writeError(w, err)
		return
	}
	if partner == nil {
		writeError(w, &apiError{http.StatusNotFound, "no_partner", "partner is not registered yet"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"partner": viewUser(partner), "server_time": time.Now().Unix()})
}

func (s *Server) handleGetUser(w http.ResponseWriter, r *http.Request) {
	sess := sessionFrom(r)
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, errBadRequest("invalid_user_id", "invalid user id"))
		return
	}
	if id != sess.UserID {
		partner, err := s.db.GetPartner(sess.UserID)
		if err != nil {
			writeError(w, err)
			return
		}
		if partner == nil || partner.ID != id {
			writeError(w, errForbidden)
			return
		}
	}
	user, err := s.db.GetUserByID(id)
	if err != nil {
		writeError(w, err)
		return
	}
	if user == nil {
		writeError(w, errNotFound)
		return
	}
	writeJSON(w, http.StatusOK, viewUser(user))
}

// handlePanic — ручной вайп. Только админ, с повторным вводом пароля.
func (s *Server) handlePanic(w http.ResponseWriter, r *http.Request) {
	if s.rateLimited(w, r) {
		return
	}
	sess := sessionFrom(r)
	var req struct {
		Password string `json:"password"`
		Confirm  string `json:"confirm"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, err)
		return
	}
	user, err := s.db.GetUserByID(sess.UserID)
	if err != nil || user == nil {
		writeError(w, errUnauthorized)
		return
	}
	if !user.IsAdmin {
		writeError(w, &apiError{http.StatusForbidden, "admin_required", "admin access required"})
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(req.Password)) != nil {
		s.authRL.Fail(clientIP(r))
		writeError(w, errInvalidCredentials)
		return
	}
	if req.Confirm != "DESTROY_ALL_DATA" {
		writeError(w, errBadRequest("invalid_confirmation", "confirm must be DESTROY_ALL_DATA"))
		return
	}
	log.Printf("🚨 PANIC requested via API by admin %s", user.Username)
	writeJSON(w, http.StatusOK, map[string]string{"status": "panic_initiated"})
	go func() {
		time.Sleep(500 * time.Millisecond)
		s.panic.Trigger(panic.ReasonManual)
	}()
}

func (s *Server) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	sess := sessionFrom(r)
	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade error: %v", err)
		return
	}
	client := s.hub.Register(conn, sess.UserID, sess.DeviceID)
	go client.Run()
}
