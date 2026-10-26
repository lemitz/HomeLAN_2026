package server

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"strings"
	"time"

	"homelan-server/internal/models"
)

type ctxKey int

const sessionKey ctxKey = 0

func generateToken() (token, hash string) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic("crypto/rand failed: " + err.Error())
	}
	token = hex.EncodeToString(b)
	return token, hashToken(token)
}

func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func (s *Server) sessionTTL() time.Duration {
	return time.Duration(s.cfg.Security.SessionDays) * 24 * time.Hour
}

func (s *Server) newSession(userID int64, deviceID string) (string, error) {
	token, hash := generateToken()
	if _, err := s.db.CreateSession(userID, deviceID, hash, s.sessionTTL()); err != nil {
		return "", err
	}
	return token, nil
}

// authenticate проверяет токен из заголовка Authorization: Bearer <token>.
// Сессия должна быть активной, а её устройство — существующим и не отозванным.
func (s *Server) authenticate(r *http.Request) (*models.Session, error) {
	auth := r.Header.Get("Authorization")
	token, ok := strings.CutPrefix(auth, "Bearer ")
	if !ok || len(token) != 64 {
		return nil, errUnauthorized
	}
	sess, err := s.db.GetSessionByTokenHash(hashToken(token))
	if err != nil {
		return nil, err
	}
	if sess == nil || sess.IsRevoked || time.Now().Unix() > sess.ExpiresAt {
		return nil, errUnauthorized
	}
	dev, err := s.db.GetDevice(sess.DeviceID)
	if err != nil {
		return nil, err
	}
	if dev == nil || dev.IsRevoked || dev.UserID != sess.UserID {
		return nil, errUnauthorized
	}
	// Скользящий срок жизни: продлеваем не чаще раза в час.
	if time.Now().Unix()-sess.LastUsed > 3600 {
		s.db.ExtendSession(sess.ID, s.sessionTTL())
	}
	s.touchActivity(sess.UserID, sess.DeviceID)
	return sess, nil
}

// auth — middleware, требующий валидную сессию.
func (s *Server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sess, err := s.authenticate(r)
		if err != nil {
			writeError(w, err)
			return
		}
		next(w, r.WithContext(context.WithValue(r.Context(), sessionKey, sess)))
	}
}

func sessionFrom(r *http.Request) *models.Session {
	return r.Context().Value(sessionKey).(*models.Session)
}
