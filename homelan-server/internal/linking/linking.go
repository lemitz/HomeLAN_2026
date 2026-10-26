// Package linking — одноразовые коды привязки нового устройства.
//
// Поток (2-QR, см. docs/ARCHITECTURE.md):
//  1. Новое устройство показывает QR#1: свой device_id и эфемерный публичный ключ.
//  2. Старое устройство (авторизовано) сканирует его и вызывает
//     /api/devices/link/create с device_id нового устройства — получает код,
//     привязанный к этому device_id.
//  3. Старое устройство шифрует identity-ключ эфемерным ключом и показывает
//     QR#2 (или текст) с кодом и шифротекстом. Сервер ключ не видит.
//  4. Новое устройство вызывает /api/devices/link/complete с кодом.
package linking

import (
	"crypto/rand"
	"strings"
	"sync"
	"time"
)

// TTL кода привязки.
const TTL = 5 * time.Minute

// Алфавит без похожих символов (0/O, 1/I/L).
const alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

// PendingLink — ожидающая привязка.
type PendingLink struct {
	Code       string
	UserID     int64
	DeviceID   string
	DeviceName string
	DeviceType string
	ExpiresAt  time.Time
}

type LinkingService struct {
	mu      sync.Mutex
	pending map[string]*PendingLink
	stop    chan struct{}
}

func NewLinkingService() *LinkingService {
	ls := &LinkingService{pending: make(map[string]*PendingLink), stop: make(chan struct{})}
	go ls.cleanupLoop()
	return ls
}

// Close останавливает фоновую очистку.
func (ls *LinkingService) Close() { close(ls.stop) }

// generateCode — 10 символов из 31 (~49 бит), формат XXXXX-XXXXX.
func generateCode() string {
	buf := make([]byte, 10)
	out := make([]byte, 0, 11)
	for i := 0; i < len(buf); {
		if _, err := rand.Read(buf[i : i+1]); err != nil {
			panic(err)
		}
		// Отбрасываем значения, дающие смещение распределения.
		if int(buf[i]) >= 256-(256%len(alphabet)) {
			continue
		}
		out = append(out, alphabet[int(buf[i])%len(alphabet)])
		if i == 4 {
			out = append(out, '-')
		}
		i++
	}
	return string(out)
}

// Normalize приводит введённый код к каноническому виду.
func Normalize(code string) string {
	code = strings.ToUpper(strings.TrimSpace(code))
	code = strings.NewReplacer("-", "", " ", "").Replace(code)
	if len(code) == 10 {
		return code[:5] + "-" + code[5:]
	}
	return code
}

// CreateLink создаёт код для привязки устройства deviceID к пользователю.
// Предыдущие коды этого пользователя аннулируются.
func (ls *LinkingService) CreateLink(userID int64, deviceID, deviceName, deviceType string) *PendingLink {
	ls.mu.Lock()
	defer ls.mu.Unlock()

	for code, l := range ls.pending {
		if l.UserID == userID {
			delete(ls.pending, code)
		}
	}

	code := generateCode()
	for ls.pending[code] != nil {
		code = generateCode()
	}
	link := &PendingLink{
		Code:       code,
		UserID:     userID,
		DeviceID:   deviceID,
		DeviceName: deviceName,
		DeviceType: deviceType,
		ExpiresAt:  time.Now().Add(TTL),
	}
	ls.pending[code] = link
	return link
}

// Consume возвращает и удаляет привязку по коду. Код одноразовый: он
// сгорает даже при несовпадении device_id (защита от перебора).
func (ls *LinkingService) Consume(code, deviceID string) *PendingLink {
	ls.mu.Lock()
	defer ls.mu.Unlock()

	code = Normalize(code)
	link, ok := ls.pending[code]
	if !ok {
		return nil
	}
	delete(ls.pending, code)
	if time.Now().After(link.ExpiresAt) || link.DeviceID != deviceID {
		return nil
	}
	return link
}

func (ls *LinkingService) cleanupLoop() {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ls.stop:
			return
		case <-ticker.C:
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
}
