// Package ws — WebSocket-канал HomeLAN (протокол v2, см. docs/ARCHITECTURE.md).
package ws

import (
	"encoding/json"
	"log"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"homelan-server/internal/db"
	"homelan-server/internal/models"
)

const (
	writeWait      = 10 * time.Second
	pongWait       = 60 * time.Second
	pingPeriod     = 30 * time.Second
	maxMessageSize = 256 * 1024 // входящий кадр
	sendBuffer     = 512
)

// Hub хранит активные подключения (одно на устройство).
type Hub struct {
	db      *db.Database
	mu      sync.RWMutex
	clients map[string]*Client // deviceID -> Client

	// OnActivity вызывается на каждое входящее сообщение (для last_seen).
	OnActivity func(userID int64, deviceID string)
	// OnFileReleased вызывается, когда файл больше не нужен (сообщение удалено).
	OnFileReleased func(fileID string)
}

func NewHub(database *db.Database) *Hub {
	return &Hub{db: database, clients: make(map[string]*Client)}
}

// Client — одно WebSocket-подключение устройства.
type Client struct {
	hub       *Hub
	conn      *websocket.Conn
	send      chan []byte
	done      chan struct{}
	closeOnce sync.Once
	userID    int64
	deviceID  string
}

// close закрывает подключение. Канал send никогда не закрывается —
// это исключает панику "send on closed channel" у конкурентных отправителей.
func (c *Client) close() {
	c.closeOnce.Do(func() {
		close(c.done)
		if c.conn != nil {
			c.conn.Close()
		}
	})
}

// enqueue кладёт данные в очередь клиента. Если клиент не успевает читать,
// соединение закрывается: при переподключении он досинхронизируется по курсору.
func (c *Client) enqueue(data []byte) {
	select {
	case <-c.done:
		return
	default:
	}
	select {
	case c.send <- data:
	case <-c.done:
	default:
		log.Printf("⚠️ Send buffer full for device=%s, dropping connection", c.deviceID)
		c.close()
	}
}

// Register регистрирует подключение, вытесняя предыдущее с того же устройства.
func (h *Hub) Register(conn *websocket.Conn, userID int64, deviceID string) *Client {
	c := &Client{
		hub:      h,
		conn:     conn,
		send:     make(chan []byte, sendBuffer),
		done:     make(chan struct{}),
		userID:   userID,
		deviceID: deviceID,
	}
	h.mu.Lock()
	if old := h.clients[deviceID]; old != nil {
		old.close()
	}
	h.clients[deviceID] = c
	h.mu.Unlock()
	log.Printf("📱 Client connected: device=%s user=%d", deviceID, userID)
	return c
}

func (h *Hub) unregister(c *Client) {
	h.mu.Lock()
	if h.clients[c.deviceID] == c {
		delete(h.clients, c.deviceID)
	}
	h.mu.Unlock()
	c.close()
	log.Printf("📴 Client disconnected: device=%s", c.deviceID)
}

// SendToUser отправляет данные всем подключённым устройствам пользователя.
func (h *Hub) SendToUser(userID int64, data []byte, excludeDevice string) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for id, c := range h.clients {
		if c.userID == userID && id != excludeDevice {
			c.enqueue(data)
		}
	}
}

// SendToDevice отправляет данные одному устройству.
func (h *Hub) SendToDevice(deviceID string, data []byte) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	if c := h.clients[deviceID]; c != nil {
		c.enqueue(data)
	}
}

func (h *Hub) IsDeviceOnline(deviceID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	_, ok := h.clients[deviceID]
	return ok
}

// DisconnectDevice принудительно закрывает подключение устройства (при отзыве).
func (h *Hub) DisconnectDevice(deviceID string) {
	h.mu.Lock()
	c := h.clients[deviceID]
	delete(h.clients, deviceID)
	h.mu.Unlock()
	if c != nil {
		c.close()
	}
}

// CloseAll закрывает все подключения (при остановке сервера).
func (h *Hub) CloseAll() {
	h.mu.Lock()
	clients := h.clients
	h.clients = make(map[string]*Client)
	h.mu.Unlock()
	for _, c := range clients {
		c.close()
	}
}

// Envelope — обёртка всех сообщений канала.
type Envelope struct {
	Type string          `json:"type"`
	Data json.RawMessage `json:"data"`
}

func encode(typ string, data any) []byte {
	b, err := json.Marshal(map[string]any{"type": typ, "data": data})
	if err != nil {
		log.Printf("ws encode error: %v", err)
		return nil
	}
	return b
}

// PublishMessage рассылает актуальное состояние сообщения обоим участникам.
func (h *Hub) PublishMessage(m *models.Message) {
	if m == nil {
		return
	}
	data := encode("message", m)
	h.SendToUser(m.SenderID, data, "")
	if m.RecipientID != m.SenderID {
		h.SendToUser(m.RecipientID, data, "")
	}
}
