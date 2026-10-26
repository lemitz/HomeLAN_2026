package server

import (
	"errors"
	"log"
	"net/http"
	"strconv"
	"time"

	"homelan-server/internal/db"
)

func (s *Server) handleDevicesList(w http.ResponseWriter, r *http.Request) {
	sess := sessionFrom(r)
	devices, err := s.db.ListUserDevices(sess.UserID)
	if err != nil {
		writeError(w, err)
		return
	}
	list := make([]map[string]any, 0, len(devices))
	for _, d := range devices {
		list = append(list, map[string]any{
			"device_id":   d.DeviceID,
			"device_name": d.DeviceName,
			"device_type": d.DeviceType,
			"created_at":  d.CreatedAt,
			"last_seen":   d.LastSeen,
			"is_online":   s.hub.IsDeviceOnline(d.DeviceID),
			"is_current":  d.DeviceID == sess.DeviceID,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"devices":     list,
		"max_devices": s.cfg.Security.MaxDevicesPerUser,
		"server_time": time.Now().Unix(),
	})
}

func (s *Server) handleDeviceRevoke(w http.ResponseWriter, r *http.Request) {
	sess := sessionFrom(r)
	var req struct {
		DeviceID string `json:"device_id"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, err)
		return
	}
	device, err := s.db.GetDevice(req.DeviceID)
	if err != nil {
		writeError(w, err)
		return
	}
	if device == nil || device.UserID != sess.UserID || device.IsRevoked {
		writeError(w, errNotFound)
		return
	}
	if err := s.db.RevokeDevice(req.DeviceID); err != nil {
		writeError(w, err)
		return
	}
	s.hub.DisconnectDevice(req.DeviceID)
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "server_time": time.Now().Unix()})
	log.Printf("🚫 Device revoked: %s by user %d", req.DeviceID, sess.UserID)
}

// handleLinkCreate вызывается старым (авторизованным) устройством после
// сканирования QR#1 нового устройства. Код привязывается к device_id нового.
func (s *Server) handleLinkCreate(w http.ResponseWriter, r *http.Request) {
	sess := sessionFrom(r)
	var req struct {
		DeviceID   string `json:"device_id"`
		DeviceName string `json:"device_name"`
		DeviceType string `json:"device_type"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, err)
		return
	}
	name, err := validateDevice(req.DeviceID, req.DeviceName, req.DeviceType)
	if err != nil {
		writeError(w, err)
		return
	}
	exists, err := s.db.DeviceExists(req.DeviceID)
	if err != nil {
		writeError(w, err)
		return
	}
	if exists {
		writeError(w, &apiError{http.StatusConflict, "device_exists", "device already registered"})
		return
	}
	active, err := s.db.CountActiveDevices(sess.UserID)
	if err != nil {
		writeError(w, err)
		return
	}
	if active >= s.cfg.Security.MaxDevicesPerUser {
		writeError(w, &apiError{http.StatusForbidden, "device_limit",
			"device limit reached (" + strconv.Itoa(s.cfg.Security.MaxDevicesPerUser) + "), revoke an old device first"})
		return
	}

	link := s.links.CreateLink(sess.UserID, req.DeviceID, name, req.DeviceType)
	writeJSON(w, http.StatusOK, map[string]any{
		"link_code":   link.Code,
		"expires_at":  link.ExpiresAt.Unix(),
		"server_time": time.Now().Unix(),
	})
	log.Printf("🔗 Link code created for user %d → device %s", sess.UserID, req.DeviceID)
}

// handleLinkComplete вызывается новым устройством (без сессии) с кодом из QR#2.
func (s *Server) handleLinkComplete(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if ok, wait := s.linkRL.Allow(ip); !ok {
		w.Header().Set("Retry-After", strconv.Itoa(int(wait.Seconds())+1))
		writeError(w, &apiError{http.StatusTooManyRequests, "rate_limited", "too many attempts"})
		return
	}
	var req struct {
		LinkCode string `json:"link_code"`
		DeviceID string `json:"device_id"`
	}
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, err)
		return
	}
	link := s.links.Consume(req.LinkCode, req.DeviceID)
	if link == nil {
		s.linkRL.Fail(ip)
		writeError(w, errBadRequest("invalid_link_code", "invalid or expired link code"))
		return
	}
	s.linkRL.Success(ip)

	user, err := s.db.GetUserByID(link.UserID)
	if err != nil || user == nil {
		writeError(w, errNotFound)
		return
	}
	device, err := s.db.CreateDevice(link.UserID, link.DeviceID, link.DeviceName, link.DeviceType,
		s.cfg.Security.MaxDevicesPerUser)
	switch {
	case errors.Is(err, db.ErrDeviceExists):
		writeError(w, &apiError{http.StatusConflict, "device_exists", "device already registered"})
		return
	case errors.Is(err, db.ErrDeviceLimit):
		writeError(w, &apiError{http.StatusForbidden, "device_limit", "device limit reached"})
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
	log.Printf("🔗 Device linked: %s → user %s", device.DeviceID, user.Username)
}
