package linking

import (
	"crypto/rand"
	"encoding/base64"
	"strings"
	"sync"
	"time"
)

// PendingLink хранит информацию об ожидающей привязке
type PendingLink struct {
	Code      string
	UserID    int64
	CreatedAt time.Time
	ExpiresAt time.Time
}

// LinkingService управляет привязкой устройств
type LinkingService struct {
	pending map[string]*PendingLink
	mu      sync.RWMutex
}

// NewLinkingService создаёт новый сервис
func NewLinkingService() *LinkingService {
	ls := &LinkingService{
		pending: make(map[string]*PendingLink),
	}
	go ls.cleanupLoop()
	return ls
}

// generateCode создаёт случайный код (формат XXXX-XXXX)
func generateCode() string {
	bytes := make([]byte, 6)
	rand.Read(bytes)
	raw := strings.ToUpper(base64.RawURLEncoding.EncodeToString(bytes))
	// Убираем похожие символы (0/O, 1/I/L)
	raw = strings.ReplaceAll(raw, "0", "X")
	raw = strings.ReplaceAll(raw, "O", "Y")
	raw = strings.ReplaceAll(raw, "1", "Z")
	raw = strings.ReplaceAll(raw, "I", "W")
	raw = strings.ReplaceAll(raw, "L", "V")
	// Формат XXXX-XXXX
	if len(raw) >= 8 {
		return raw[:4] + "-" + raw[4:8]
	}
	return raw
}

// CreateLink создаёт код для привязки нового устройства
// Теперь принимает только userID — device info придёт от нового устройства
func (ls *LinkingService) CreateLink(userID int64) *PendingLink {
	ls.mu.Lock()
	defer ls.mu.Unlock()

	code := generateCode()

	link := &PendingLink{
		Code:      code,
		UserID:    userID,
		CreatedAt: time.Now(),
		ExpiresAt: time.Now().Add(5 * time.Minute),
	}

	ls.pending[code] = link
	return link
}

// GetLink возвращает и удаляет привязку по коду
func (ls *LinkingService) GetLink(code string) *PendingLink {
	ls.mu.Lock()
	defer ls.mu.Unlock()

	// Нормализуем код (upper case, с дефисом или без)
	code = strings.ToUpper(strings.TrimSpace(code))

	link, ok := ls.pending[code]
	if !ok {
		// Попробуем без дефиса
		codeNoDash := strings.ReplaceAll(code, "-", "")
		for c, l := range ls.pending {
			if strings.ReplaceAll(c, "-", "") == codeNoDash {
				link = l
				code = c
				ok = true
				break
			}
		}
	}

	if !ok {
		return nil
	}

	if time.Now().After(link.ExpiresAt) {
		delete(ls.pending, code)
		return nil
	}

	delete(ls.pending, code)
	return link
}

// cleanupLoop удаляет устаревшие коды
func (ls *LinkingService) cleanupLoop() {
	ticker := time.NewTicker(1 * time.Minute)
	for range ticker.C {
		ls.mu.Lock()
		now := time.Now()
		for code, link := range ls.pending {
			if now.After(link.ExpiresAt) {
				delete(ls.pending, code)
			}
		}
		ls.mu.Unlock()
	}
}