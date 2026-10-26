package server

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"regexp"
	"strings"
	"unicode/utf8"
)

const maxJSONBody = 64 * 1024

// apiError — единый формат ошибки API: {"error": "<code>", "message": "..."}.
type apiError struct {
	status  int
	code    string
	message string
}

func (e *apiError) Error() string { return e.code + ": " + e.message }

func errBadRequest(code, msg string) *apiError { return &apiError{http.StatusBadRequest, code, msg} }

var (
	errUnauthorized       = &apiError{http.StatusUnauthorized, "unauthorized", "authentication required"}
	errInvalidCredentials = &apiError{http.StatusUnauthorized, "invalid_credentials", "invalid username or password"}
	errForbidden          = &apiError{http.StatusForbidden, "forbidden", "access denied"}
	errNotFound           = &apiError{http.StatusNotFound, "not_found", "not found"}
	errInternal           = &apiError{http.StatusInternalServerError, "internal_error", "internal server error"}
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("write response: %v", err)
	}
}

func writeError(w http.ResponseWriter, err error) {
	var ae *apiError
	if !errors.As(err, &ae) {
		log.Printf("internal error: %v", err)
		ae = errInternal
	}
	writeJSON(w, ae.status, map[string]string{"error": ae.code, "message": ae.message})
}

// decodeJSON читает JSON-тело с ограничением размера. Неизвестные поля
// допускаются (клиенты разных версий могут присылать больше полей).
func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxJSONBody)
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(dst); err != nil {
		return errBadRequest("invalid_json", "invalid JSON body")
	}
	if dec.Decode(&struct{}{}) != io.EOF {
		return errBadRequest("invalid_json", "unexpected data after JSON body")
	}
	return nil
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// ============ ВАЛИДАЦИЯ ============

var (
	usernameRe = regexp.MustCompile(`^[\p{L}\p{N}_.-]{3,32}$`)
	deviceIDRe = regexp.MustCompile(`^[A-Za-z0-9_-]{16,64}$`)
	fileIDRe   = regexp.MustCompile(`^[a-f0-9]{32}$`)
)

var deviceTypes = map[string]bool{"android": true, "windows": true, "linux": true, "macos": true, "ios": true}

func validateUsername(s string) error {
	if !usernameRe.MatchString(s) {
		return errBadRequest("invalid_username", "username: 3-32 letters, digits, '_', '.', '-'")
	}
	return nil
}

func validatePassword(s string) error {
	if utf8.RuneCountInString(s) < 8 {
		return errBadRequest("weak_password", "password must be at least 8 characters")
	}
	if len(s) > 72 {
		return errBadRequest("invalid_password", "password is too long (max 72 bytes)")
	}
	return nil
}

func validateDevice(id, name, typ string) (string, error) {
	if !deviceIDRe.MatchString(id) {
		return "", errBadRequest("invalid_device_id", "invalid device_id")
	}
	if !deviceTypes[typ] {
		return "", errBadRequest("invalid_device_type", "invalid device_type")
	}
	name = strings.TrimSpace(name)
	if name == "" {
		name = typ
	}
	if utf8.RuneCountInString(name) > 64 {
		return "", errBadRequest("invalid_device_name", "device_name is too long")
	}
	return name, nil
}

func validatePublicKey(k []byte) error {
	if len(k) != 32 {
		return errBadRequest("invalid_public_key", "public_key must be 32 bytes (X25519)")
	}
	return nil
}
