package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/crypto/bcrypt"
	"homelan-server/internal/db"
	"homelan-server/internal/models"
	"homelan-server/internal/utils"
)

// ============ Общие хелперы ============

const (
	maxJSONBody    = 64 << 10 // лимит тела JSON-запросов
	maxPasswordLen = 72       // ограничение bcrypt
	minPasswordLen = 8
	publicKeySize  = 32 // X25519
)

var (
	usernameRe = regexp.MustCompile(`^[A-Za-z0-9_.-]{3,32}$`)
	deviceIDRe = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
	fileIDRe   = regexp.MustCompile(`^[0-9a-f]{32}$`)

	// dummyBcryptHash используется для выравнивания времени ответа при логине
	// несуществующего пользователя (иначе по времени ответа можно перебирать имена).
	dummyBcryptHash []byte
)

func init() {
	h, err := bcrypt.GenerateFromPassword([]byte("homelan-dummy-password-for-timing"), bcrypt.DefaultCost)
	if err != nil {
		log.Fatalf("bcrypt init failed: %v", err)
	}
	dummyBcryptHash = h
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// decodeJSON читает JSON с ограничением размера тела
func decodeJSON(w http.ResponseWriter, r *http.Request, v interface{}) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxJSONBody)
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(v); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			http.Error(w, "Request body too large", http.StatusRequestEntityTooLarge)
		} else {
			http.Error(w, "Invalid JSON", http.StatusBadRequest)
		}
		return false
	}
	return true
}

func requireMethod(w http.ResponseWriter, r *http.Request, method string) bool {
	if r.Method != method {
		w.Header().Set("Allow", method)
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return false
	}
	return true
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func validateUsername(u string) error {
	if !usernameRe.MatchString(u) {
		return errors.New("username must be 3-32 characters: letters, digits, '_', '.', '-'")
	}
	return nil
}

func validateNewPassword(p string) error {
	if len(p) < minPasswordLen {
		return fmt.Errorf("password must be at least %d characters", minPasswordLen)
	}
	if len(p) > maxPasswordLen {
		return fmt.Errorf("password must be at most %d bytes", maxPasswordLen)
	}
	return nil
}

func validateDeviceID(id string) error {
	if !deviceIDRe.MatchString(id) {
		return errors.New("device_id must be 1-64 characters: letters, digits, '_', '-'")
	}
	return nil
}

// validatePublicKey: ключ либо отсутствует, либо ровно 32 байта (X25519)
func validatePublicKey(k []byte) error {
	if len(k) != 0 && len(k) != publicKeySize {
		return fmt.Errorf("public_key must be %d bytes", publicKeySize)
	}
	return nil
}

// truncateRunes обрезает строку до max рун и убирает управляющие символы
func truncateRunes(s string, max int) string {
	s = strings.TrimSpace(s)
	if !utf8.ValidString(s) {
		s = strings.ToValidUTF8(s, "")
	}
	var b strings.Builder
	n := 0
	for _, r := range s {
		if r < 0x20 || r == 0x7f {
			continue
		}
		if n >= max {
			break
		}
		b.WriteRune(r)
		n++
	}
	return b.String()
}

func generateFileID() string {
	bytes := make([]byte, 16)
	if _, err := rand.Read(bytes); err != nil {
		log.Fatalf("failed to read secure random: %v", err)
	}
	return hex.EncodeToString(bytes)
}

func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func generateSessionToken() (string, string) {
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		log.Fatalf("failed to read secure random: %v", err)
	}
	token := hex.EncodeToString(bytes)
	return token, hashToken(token)
}

// ============ Аутентификация ============

var (
	errNoToken        = errors.New("missing token")
	errInvalidSession = errors.New("invalid session")
	errDeviceRevoked  = errors.New("device revoked")
)

// authenticate извлекает токен ТОЛЬКО из заголовков (X-Session-Token или
// Authorization: Bearer). Токен в query-строке/Sec-WebSocket-Protocol больше не
// принимается: он попадал в логи, историю и был доступен любому прокси.
func (s *Server) authenticate(r *http.Request) (*models.Session, error) {
	token := r.Header.Get("X-Session-Token")
	if token == "" {
		if auth := r.Header.Get("Authorization"); strings.HasPrefix(auth, "Bearer ") {
			token = strings.TrimSpace(strings.TrimPrefix(auth, "Bearer "))
		}
	}
	if token == "" {
		return nil, errNoToken
	}
	if len(token) != 64 {
		return nil, errInvalidSession
	}

	tokenHash := hashToken(token)
	session, err := s.db.GetSessionByTokenHash(tokenHash)
	if err != nil {
		return nil, fmt.Errorf("session lookup: %w", err)
	}
	if session == nil {
		return nil, errInvalidSession
	}
	// Отозванное устройство проверяем первым: RevokeDevice помечает и сессии,
	// а клиенту важно отличать «устройство отозвано» (403, полная очистка)
	// от «сессия закончилась» (401, просто перелогин).
	if session.DeviceRevoked {
		return nil, errDeviceRevoked
	}
	if session.IsRevoked {
		return nil, errInvalidSession
	}

	now := time.Now().Unix()
	if now > session.ExpiresAt {
		return nil, errInvalidSession
	}

	// Скользящий срок: активная сессия продлевается, когда до истечения осталось
	// меньше половины срока. Неактивная истекает через 30 дней.
	if time.Duration(session.ExpiresAt-now)*time.Second < sessionRenewThreshold {
		if newExp, err := s.db.ExtendSession(tokenHash, sessionDuration); err == nil {
			session.ExpiresAt = newExp
		}
	}

	return session, nil
}

// requireAuth отвечает 401 (или 403 для отозванного устройства) и возвращает nil,
// если запрос не аутентифицирован. Текст ошибки намеренно общий.
func (s *Server) requireAuth(w http.ResponseWriter, r *http.Request) *models.Session {
	session, err := s.authenticate(r)
	if err == nil {
		return session
	}
	if errors.Is(err, errDeviceRevoked) {
		http.Error(w, "Device revoked", http.StatusForbidden)
		return nil
	}
	if !errors.Is(err, errNoToken) && !errors.Is(err, errInvalidSession) {
		log.Printf("authenticate error: %v", err)
	}
	http.Error(w, "Unauthorized", http.StatusUnauthorized)
	return nil
}

// ============ Простые эндпоинты ============

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":      "ok",
		"server_time": time.Now().Unix(),
	})
}

func (s *Server) handleTime(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"server_time": time.Now().Unix(),
	})
}

func (s *Server) handlePanic(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodPost) {
		return
	}

	session := s.requireAuth(w, r)
	if session == nil {
		return
	}

	user, err := s.db.GetUserByID(session.UserID)
	if err != nil || user == nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	if !user.IsAdmin {
		http.Error(w, "Forbidden: Admin access required", http.StatusForbidden)
		return
	}

	var req struct {
		Confirm string `json:"confirm"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}

	if req.Confirm != "DESTROY_ALL_DATA" {
		http.Error(w, "Invalid confirmation", http.StatusBadRequest)
		return
	}

	log.Printf("🚨 PANIC INITIATED via API by admin user: %s (ID: %d)", user.Username, user.ID)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status": "panic_initiated",
	})

	go func() {
		time.Sleep(500 * time.Millisecond)
		s.panicHandler.Trigger("MANUAL_PANIC_API")
	}()
}

func (s *Server) handleGetUser(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}

	session := s.requireAuth(w, r)
	if session == nil {
		return
	}

	userIDStr := strings.TrimPrefix(r.URL.Path, "/api/user/")
	userID, err := strconv.ParseInt(userIDStr, 10, 64)
	if err != nil || userID <= 0 {
		http.Error(w, "Invalid user ID", http.StatusBadRequest)
		return
	}

	// Разрешены только свои данные или данные партнёра (система на 2 пользователей)
	if userID != session.UserID {
		partner, err := s.db.GetPartner(session.UserID)
		if err != nil {
			http.Error(w, "Internal error", http.StatusInternalServerError)
			return
		}
		if partner == nil || partner.ID != userID {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
	}

	user, err := s.db.GetUserByID(userID)
	if err != nil {
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}
	if user == nil {
		http.Error(w, "User not found", http.StatusNotFound)
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"id":         user.ID,
		"username":   user.Username,
		"public_key": user.PublicKey,
		"is_admin":   user.IsAdmin,
	})
}

func (s *Server) handleGetPartner(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}

	session := s.requireAuth(w, r)
	if session == nil {
		return
	}

	partner, err := s.db.GetPartner(session.UserID)
	if err != nil {
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}
	if partner == nil {
		http.Error(w, "No partner found", http.StatusNotFound)
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"id":          partner.ID,
		"username":    partner.Username,
		"public_key":  partner.PublicKey,
		"server_time": time.Now().Unix(),
	})
}

// ============ WebSocket ============

func (s *Server) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	session := s.requireAuth(w, r)
	if session == nil {
		return
	}

	deviceID := r.URL.Query().Get("device_id")
	if deviceID != "" && deviceID != session.DeviceID {
		http.Error(w, "Forbidden: device ID mismatch", http.StatusForbidden)
		return
	}

	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade error: %v", err)
		return
	}

	client := s.hub.RegisterClient(conn, session.UserID, session.DeviceID)
	s.db.UpdateDeviceLastSeen(session.DeviceID)
	s.db.UpdateUserLastSeen(session.UserID)

	go client.WritePump()
	go client.ReadPump()
}

// ============ Регистрация / логин / логаут ============

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodPost) {
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
	if !decodeJSON(w, r, &req) {
		return
	}

	if err := validateUsername(req.Username); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := validateNewPassword(req.Password); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := validateDeviceID(req.DeviceID); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := validatePublicKey(req.PublicKey); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	deviceName := truncateRunes(req.DeviceName, 64)
	deviceType := truncateRunes(req.DeviceType, 32)
	if deviceName == "" {
		deviceName = "Unknown"
	}
	if deviceType == "" {
		deviceType = "unknown"
	}

	// Проверка лимита и создание пользователя должны быть атомарны:
	// два одновременных запроса не должны обойти max_users или оба стать админами.
	s.registerMu.Lock()
	defer s.registerMu.Unlock()

	userCount, err := s.db.GetUserCount()
	if err != nil {
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}
	if userCount >= s.config.Security.MaxUsers {
		http.Error(w, "Maximum users reached", http.StatusForbidden)
		return
	}

	existing, err := s.db.GetUserByUsername(req.Username)
	if err != nil {
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}
	if existing != nil {
		http.Error(w, "Username already exists", http.StatusConflict)
		return
	}

	// device_id занят (в т.ч. отозван) — нельзя «перехватить» чужое устройство
	if existingDevice, err := s.db.GetDeviceByID(req.DeviceID); err != nil {
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	} else if existingDevice != nil {
		http.Error(w, "Device already registered", http.StatusConflict)
		return
	}

	admin, err := s.db.GetAdmin()
	if err != nil {
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}
	isAdmin := admin == nil

	user, err := s.db.CreateUser(req.Username, req.Password, isAdmin)
	if err != nil {
		log.Printf("CreateUser error: %v", err)
		http.Error(w, "Failed to create user", http.StatusInternalServerError)
		return
	}

	if len(req.PublicKey) > 0 {
		if err := s.db.UpdateUserPublicKey(user.ID, req.PublicKey); err != nil {
			log.Printf("UpdateUserPublicKey error: %v", err)
		}
	}

	device, err := s.db.CreateDevice(user.ID, req.DeviceID, deviceName, deviceType, req.PublicKey)
	if err != nil {
		if errors.Is(err, db.ErrDeviceExists) {
			http.Error(w, "Device already registered", http.StatusConflict)
			return
		}
		log.Printf("CreateDevice error: %v", err)
		http.Error(w, "Failed to create device", http.StatusInternalServerError)
		return
	}

	token, tokenHash := generateSessionToken()
	if _, err := s.db.CreateSession(user.ID, device.DeviceID, tokenHash, sessionDuration); err != nil {
		http.Error(w, "Failed to create session", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success":     true,
		"user_id":     user.ID,
		"device_id":   device.DeviceID,
		"is_admin":    isAdmin,
		"token":       token,
		"server_time": time.Now().Unix(),
	})

	log.Printf("✅ User registered: %s (admin: %v) [%d/%d]", req.Username, isAdmin, userCount+1, s.config.Security.MaxUsers)
}

// loginFailed фиксирует неудачную попытку и отвечает единым сообщением
func (s *Server) loginFailed(w http.ResponseWriter, ipKey, userKey string) {
	s.loginIPLimiter.Fail(ipKey)
	if userKey != "" {
		s.loginUserLimiter.Fail(userKey)
	}
	http.Error(w, "Invalid credentials", http.StatusUnauthorized)
}

func tooManyRequests(w http.ResponseWriter, wait time.Duration) {
	secs := int(wait.Seconds()) + 1
	w.Header().Set("Retry-After", strconv.Itoa(secs))
	http.Error(w, fmt.Sprintf("Too many attempts, retry in %d seconds", secs), http.StatusTooManyRequests)
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodPost) {
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
	if !decodeJSON(w, r, &req) {
		return
	}

	ip := clientIP(r)
	ipKey := "login:" + ip
	userKey := ipKey + ":" + strings.ToLower(req.Username)

	if ok, wait := s.loginIPLimiter.Allow(ipKey); !ok {
		tooManyRequests(w, wait)
		return
	}
	if ok, wait := s.loginUserLimiter.Allow(userKey); !ok {
		tooManyRequests(w, wait)
		return
	}

	if validateUsername(req.Username) != nil || req.Password == "" || len(req.Password) > maxPasswordLen {
		s.loginFailed(w, ipKey, "")
		return
	}
	if err := validateDeviceID(req.DeviceID); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := validatePublicKey(req.PublicKey); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// Duress-пароль: сравнение за постоянное время, срабатывает независимо от
	// существования пользователя, ответ неотличим от обычной ошибки входа.
	if s.config.Security.DuressPassword != "" &&
		subtle.ConstantTimeCompare([]byte(req.Password), []byte(s.config.Security.DuressPassword)) == 1 {
		log.Printf("🚨 DURESS PASSWORD ENTERED! Triggering emergency wipe")
		go func() {
			time.Sleep(500 * time.Millisecond)
			s.panicHandler.Trigger("DURESS_PASSWORD")
		}()
		// Тратим столько же времени, сколько обычная проверка
		bcrypt.CompareHashAndPassword(dummyBcryptHash, []byte(req.Password))
		s.loginFailed(w, ipKey, userKey)
		return
	}

	user, err := s.db.GetUserByUsername(req.Username)
	if err != nil {
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}

	if user == nil {
		// Выравниваем время ответа с реальной проверкой bcrypt
		bcrypt.CompareHashAndPassword(dummyBcryptHash, []byte(req.Password))
		s.loginFailed(w, ipKey, userKey)
		return
	}

	// Только bcrypt. Fallback на сравнение с «plaintext» удалён: он позволял
	// войти, зная сам bcrypt-хэш (pass-the-hash), и был бесполезен для БД,
	// созданных текущей версией.
	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(req.Password)); err != nil {
		s.loginFailed(w, ipKey, userKey)
		return
	}

	device, err := s.db.GetDeviceByID(req.DeviceID)
	if err != nil {
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}
	if device != nil {
		if device.UserID != user.ID {
			http.Error(w, "Device registered under another user", http.StatusForbidden)
			return
		}
		if device.IsRevoked {
			http.Error(w, "Device revoked", http.StatusForbidden)
			return
		}
	} else {
		deviceName := truncateRunes(req.DeviceName, 64)
		deviceType := truncateRunes(req.DeviceType, 32)
		if deviceName == "" {
			deviceName = "Unknown"
		}
		if deviceType == "" {
			deviceType = "unknown"
		}
		device, err = s.db.CreateDevice(user.ID, req.DeviceID, deviceName, deviceType, req.PublicKey)
		if err != nil {
			if errors.Is(err, db.ErrDeviceExists) {
				http.Error(w, "Device already registered", http.StatusConflict)
				return
			}
			http.Error(w, "Failed to register device", http.StatusInternalServerError)
			return
		}
	}

	if len(req.PublicKey) > 0 {
		if err := s.db.UpdateUserPublicKey(user.ID, req.PublicKey); err != nil {
			log.Printf("UpdateUserPublicKey error: %v", err)
		}
	}

	s.db.UpdateUserLastSeen(user.ID)
	s.db.UpdateDeviceLastSeen(device.DeviceID)

	partner, _ := s.db.GetPartner(user.ID)
	var partnerID int64
	var partnerUsername string
	var partnerPublicKey []byte
	if partner != nil {
		partnerID = partner.ID
		partnerUsername = partner.Username
		partnerPublicKey = partner.PublicKey
	}

	token, tokenHash := generateSessionToken()
	if _, err := s.db.CreateSession(user.ID, device.DeviceID, tokenHash, sessionDuration); err != nil {
		http.Error(w, "Failed to create session", http.StatusInternalServerError)
		return
	}

	s.loginIPLimiter.Reset(ipKey)
	s.loginUserLimiter.Reset(userKey)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success":            true,
		"user_id":            user.ID,
		"is_admin":           user.IsAdmin,
		"token":              token,
		"partner_id":         partnerID,
		"partner_username":   partnerUsername,
		"partner_public_key": partnerPublicKey,
		"server_time":        time.Now().Unix(),
	})

	log.Printf("✅ User logged in: %s (device %s)", user.Username, device.DeviceID)
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodPost) {
		return
	}

	session := s.requireAuth(w, r)
	if session == nil {
		return
	}

	if err := s.db.RevokeSession(session.TokenHash); err != nil {
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}

	// Активное WebSocket-соединение этого устройства тоже закрываем:
	// иначе отозванный токен продолжал бы работать до переподключения.
	s.hub.DisconnectDevice(session.DeviceID)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
	})
}

// ============ Файлы ============

// handleFileUpload принимает multipart/form-data с полем "file" (зашифрованное
// содержимое). Остальные поля игнорируются: сервер не хранит имя файла и
// MIME-тип в открытом виде — эти метаданные клиент передаёт внутри
// зашифрованного сообщения. Данные пишутся потоково во временный файл.
func (s *Server) handleFileUpload(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodPost) {
		return
	}

	session := s.requireAuth(w, r)
	if session == nil {
		return
	}
	userID := session.UserID

	// Лимит на всё тело: файл + служебные части multipart
	r.Body = http.MaxBytesReader(w, r.Body, s.maxFileSize+(1<<20))

	mr, err := r.MultipartReader()
	if err != nil {
		http.Error(w, "Expected multipart/form-data", http.StatusBadRequest)
		return
	}

	if err := os.MkdirAll(s.storagePath, 0700); err != nil {
		log.Printf("MkdirAll error: %v", err)
		http.Error(w, "Storage unavailable", http.StatusInternalServerError)
		return
	}
	if !utils.HasEnoughSpace(s.storagePath, s.maxFileSize) {
		http.Error(w, "Insufficient disk space", http.StatusInsufficientStorage)
		return
	}

	used, err := s.db.GetStorageUsed()
	if err != nil {
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}
	if used >= s.maxStorage {
		http.Error(w, "Storage quota exceeded", http.StatusInsufficientStorage)
		return
	}

	fileID := generateFileID()
	finalPath := filepath.Join(s.storagePath, fileID)
	tmpPath := finalPath + ".part"
	cleanup := func() { os.Remove(tmpPath) }

	var written int64
	gotFile := false

	for {
		part, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			cleanup()
			var maxErr *http.MaxBytesError
			if errors.As(err, &maxErr) {
				http.Error(w, "File too large", http.StatusRequestEntityTooLarge)
			} else {
				http.Error(w, "Malformed multipart body", http.StatusBadRequest)
			}
			return
		}

		if part.FormName() != "file" {
			// Служебные поля клиента (user_id, file_name, mime_type…) не используются
			io.Copy(io.Discard, io.LimitReader(part, 64<<10))
			part.Close()
			continue
		}

		if gotFile {
			part.Close()
			cleanup()
			http.Error(w, "Only one file per request", http.StatusBadRequest)
			return
		}
		gotFile = true

		dst, err := os.OpenFile(tmpPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			part.Close()
			log.Printf("Create temp file error: %v", err)
			http.Error(w, "Storage error", http.StatusInternalServerError)
			return
		}

		n, copyErr := io.Copy(dst, io.LimitReader(part, s.maxFileSize+1))
		syncErr := dst.Sync()
		closeErr := dst.Close()
		part.Close()

		if copyErr != nil {
			cleanup()
			var maxErr *http.MaxBytesError
			if errors.As(copyErr, &maxErr) {
				http.Error(w, "File too large", http.StatusRequestEntityTooLarge)
				return
			}
			log.Printf("Copy error: %v", copyErr)
			http.Error(w, "Upload failed", http.StatusInternalServerError)
			return
		}
		if syncErr != nil || closeErr != nil {
			cleanup()
			http.Error(w, "Storage error", http.StatusInternalServerError)
			return
		}
		if n > s.maxFileSize {
			cleanup()
			http.Error(w, "File too large", http.StatusRequestEntityTooLarge)
			return
		}
		if n == 0 {
			cleanup()
			http.Error(w, "Empty file", http.StatusBadRequest)
			return
		}
		written = n
	}

	if !gotFile {
		cleanup()
		http.Error(w, "No file provided", http.StatusBadRequest)
		return
	}

	if used+written > s.maxStorage {
		cleanup()
		http.Error(w, "Storage quota exceeded", http.StatusInsufficientStorage)
		return
	}

	if err := os.Rename(tmpPath, finalPath); err != nil {
		cleanup()
		log.Printf("Rename error: %v", err)
		http.Error(w, "Storage error", http.StatusInternalServerError)
		return
	}

	// Имя файла и MIME-тип в открытом виде не сохраняем
	if err := s.db.CreateFile(fileID, userID, nil, written, "application/octet-stream", finalPath); err != nil {
		os.Remove(finalPath)
		log.Printf("CreateFile DB error: %v", err)
		http.Error(w, "Database error", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"file_id": fileID,
		"size":    written,
	})

	log.Printf("📁 File uploaded: %s (%d bytes) by user %d", fileID, written, userID)
}

func (s *Server) handleFiles(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/api/files/")
	parts := strings.Split(path, "/")

	if len(parts) == 0 || parts[0] == "" || !fileIDRe.MatchString(parts[0]) {
		http.Error(w, "Invalid file ID", http.StatusBadRequest)
		return
	}
	fileID := parts[0]

	switch {
	case len(parts) == 1:
		s.handleFileDownload(w, r, fileID)
	case len(parts) == 2 && parts[1] == "info":
		s.handleFileInfo(w, r, fileID)
	default:
		http.NotFound(w, r)
	}
}

// loadFileForUser загружает метаданные файла и проверяет право доступа:
// файл доступен загрузившему и его партнёру.
func (s *Server) loadFileForUser(w http.ResponseWriter, fileID string, userID int64) *models.File {
	file, err := s.db.GetFileByID(fileID)
	if err != nil {
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return nil
	}
	if file == nil {
		http.Error(w, "File not found", http.StatusNotFound)
		return nil
	}
	if file.IsDeleted {
		http.Error(w, "File deleted", http.StatusGone)
		return nil
	}

	if file.UploaderID != userID {
		partner, err := s.db.GetPartner(file.UploaderID)
		if err != nil {
			http.Error(w, "Internal error", http.StatusInternalServerError)
			return nil
		}
		if partner == nil || partner.ID != userID {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return nil
		}
	}
	return file
}

func (s *Server) handleFileInfo(w http.ResponseWriter, r *http.Request, fileID string) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}

	session := s.requireAuth(w, r)
	if session == nil {
		return
	}

	file := s.loadFileForUser(w, fileID, session.UserID)
	if file == nil {
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"file_id":    file.ID,
		"file_size":  file.FileSize,
		"mime_type":  file.MimeType,
		"created_at": file.CreatedAt,
	})
}

func (s *Server) handleFileDownload(w http.ResponseWriter, r *http.Request, fileID string) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	session := s.requireAuth(w, r)
	if session == nil {
		return
	}

	file := s.loadFileForUser(w, fileID, session.UserID)
	if file == nil {
		return
	}

	f, err := os.Open(file.StoragePath)
	if err != nil {
		http.Error(w, "File not found", http.StatusNotFound)
		return
	}
	defer f.Close()

	stat, err := f.Stat()
	if err != nil || stat.IsDir() {
		http.Error(w, "File error", http.StatusInternalServerError)
		return
	}

	// Содержимое зашифровано клиентом — отдаём как бинарный поток.
	// http.ServeContent корректно обрабатывает Range/HEAD/If-Modified-Since.
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", "attachment; filename=\""+fileID+"\"")
	http.ServeContent(w, r, fileID, time.Unix(file.CreatedAt, 0), f)

	log.Printf("📥 File downloaded: %s by user %d", fileID, session.UserID)
}

// ============ Привязка устройств ============

func (s *Server) handleLinkCreate(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodPost) {
		return
	}

	session := s.requireAuth(w, r)
	if session == nil {
		return
	}

	var req struct {
		UserID int64 `json:"user_id"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}

	// user_id в теле — для совместимости с клиентом; авторитетен user_id сессии
	if req.UserID != 0 && req.UserID != session.UserID {
		http.Error(w, "Forbidden", http.StatusForbidden)
		return
	}

	link := s.linkingService.CreateLink(session.UserID)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success":     true,
		"link_code":   link.Code,
		"expires_at":  link.ExpiresAt.Unix(),
		"server_time": time.Now().Unix(),
	})

	// Сам код в лог не пишем — иначе он доступен всем, кто читает журнал
	log.Printf("🔗 Link code created for user %d (expires %s)", session.UserID, link.ExpiresAt.Format(time.RFC3339))
}

func (s *Server) handleLinkComplete(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodPost) {
		return
	}

	var req struct {
		LinkCode   string `json:"link_code"`
		DeviceID   string `json:"device_id"`
		DeviceName string `json:"device_name"`
		DeviceType string `json:"device_type"`
		PublicKey  []byte `json:"public_key"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}

	// Код из 8 символов живёт 5 минут — без лимита его можно перебрать
	limitKey := "link:" + clientIP(r)
	if ok, wait := s.linkLimiter.Allow(limitKey); !ok {
		tooManyRequests(w, wait)
		return
	}

	if req.LinkCode == "" || len(req.LinkCode) > 16 {
		http.Error(w, "Missing link_code", http.StatusBadRequest)
		return
	}
	if err := validateDeviceID(req.DeviceID); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := validatePublicKey(req.PublicKey); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	deviceName := truncateRunes(req.DeviceName, 64)
	deviceType := truncateRunes(req.DeviceType, 32)
	if deviceName == "" {
		deviceName = "Unknown"
	}
	if deviceType == "" {
		deviceType = "unknown"
	}

	link := s.linkingService.GetLink(req.LinkCode)
	if link == nil {
		s.linkLimiter.Fail(limitKey)
		http.Error(w, "Invalid or expired link code", http.StatusBadRequest)
		return
	}

	device, err := s.db.CreateDevice(link.UserID, req.DeviceID, deviceName, deviceType, req.PublicKey)
	if err != nil {
		if errors.Is(err, db.ErrDeviceExists) {
			http.Error(w, "Device already registered", http.StatusConflict)
			return
		}
		log.Printf("CreateDevice error: %v", err)
		http.Error(w, "Failed to create device", http.StatusInternalServerError)
		return
	}

	user, err := s.db.GetUserByID(link.UserID)
	if err != nil || user == nil {
		http.Error(w, "User not found", http.StatusNotFound)
		return
	}

	token, tokenHash := generateSessionToken()
	if _, err := s.db.CreateSession(link.UserID, device.DeviceID, tokenHash, sessionDuration); err != nil {
		http.Error(w, "Failed to create session", http.StatusInternalServerError)
		return
	}

	s.linkLimiter.Reset(limitKey)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success":     true,
		"user_id":     link.UserID,
		"username":    user.Username,
		"device_id":   device.DeviceID,
		"public_key":  user.PublicKey,
		"token":       token,
		"server_time": time.Now().Unix(),
	})

	log.Printf("🔗 Device linked: %s to user %d (%s)", device.DeviceID, link.UserID, user.Username)
}

func (s *Server) handleDevicesList(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}

	session := s.requireAuth(w, r)
	if session == nil {
		return
	}

	devices, err := s.db.GetUserDevices(session.UserID)
	if err != nil {
		http.Error(w, "Database error", http.StatusInternalServerError)
		return
	}

	deviceList := make([]map[string]interface{}, 0, len(devices))
	for _, d := range devices {
		deviceList = append(deviceList, map[string]interface{}{
			"device_id":   d.DeviceID,
			"device_name": d.DeviceName,
			"device_type": d.DeviceType,
			"created_at":  d.CreatedAt,
			"last_seen":   d.LastSeen,
			"is_online":   s.hub.IsDeviceOnline(d.DeviceID),
			"is_current":  d.DeviceID == session.DeviceID,
		})
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success":     true,
		"devices":     deviceList,
		"server_time": time.Now().Unix(),
	})
}

func (s *Server) handleDeviceRevoke(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodPost) {
		return
	}

	session := s.requireAuth(w, r)
	if session == nil {
		return
	}

	var req struct {
		UserID   int64  `json:"user_id"`
		DeviceID string `json:"device_id"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}

	if req.UserID != 0 && req.UserID != session.UserID {
		http.Error(w, "Forbidden", http.StatusForbidden)
		return
	}
	if err := validateDeviceID(req.DeviceID); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	device, err := s.db.GetDeviceByID(req.DeviceID)
	if err != nil || device == nil {
		http.Error(w, "Device not found", http.StatusNotFound)
		return
	}

	if device.UserID != session.UserID {
		http.Error(w, "Device does not belong to user", http.StatusForbidden)
		return
	}

	// Отзываем устройство и все его сессии одной транзакцией
	if err := s.db.RevokeDevice(req.DeviceID); err != nil {
		http.Error(w, "Failed to revoke device", http.StatusInternalServerError)
		return
	}

	s.hub.DisconnectDevice(req.DeviceID)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success":     true,
		"server_time": time.Now().Unix(),
	})

	log.Printf("🚫 Device revoked: %s by user %d", req.DeviceID, session.UserID)
}
