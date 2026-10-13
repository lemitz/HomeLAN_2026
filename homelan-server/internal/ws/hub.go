package ws

import (
	"encoding/json"
	"log"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"homelan-server/internal/db"
)

const (
	// Время ожидания записи
	writeWait = 10 * time.Second

	// Время между пингами
	pingPeriod = 30 * time.Second

	// Таймаут чтения (должен быть больше pingPeriod)
	pongWait = 60 * time.Second

	// Максимальный размер сообщения (1MB)
	maxMessageSize = 1024 * 1024

	// Как часто обновлять last_seen при активности (чтобы не писать в БД на каждое сообщение)
	lastSeenUpdateInterval = 30 * time.Second
)

// Client - подключённый клиент.
//
// Канал send никогда не закрывается извне: закрытие канала, в который пишет
// другая горутина (ReadPump -> sendJSON), приводило к panic "send on closed channel"
// и падению всего процесса. Вместо этого используется канал done, закрываемый
// ровно один раз через closeOnce.
type Client struct {
	hub       *Hub
	conn      *websocket.Conn
	send      chan []byte
	done      chan struct{}
	closeOnce sync.Once
	userID    int64
	deviceID  string

	lastSeenUpdate time.Time
}

func newClient(hub *Hub, conn *websocket.Conn, userID int64, deviceID string) *Client {
	return &Client{
		hub:      hub,
		conn:     conn,
		send:     make(chan []byte, 256),
		done:     make(chan struct{}),
		userID:   userID,
		deviceID: deviceID,
	}
}

// close сигнализирует WritePump завершиться. Идемпотентен и потокобезопасен.
func (c *Client) close() {
	c.closeOnce.Do(func() {
		close(c.done)
	})
}

// trySend кладёт сообщение в очередь отправки без блокировки.
// Возвращает false, если клиент закрыт или буфер переполнен.
func (c *Client) trySend(data []byte) bool {
	select {
	case <-c.done:
		return false
	default:
	}

	select {
	case c.send <- data:
		return true
	case <-c.done:
		return false
	default:
		// Буфер полон — клиент не успевает читать, сообщение придёт через sync
		return false
	}
}

// Hub - управляет всеми WebSocket подключениями
type Hub struct {
	db         *db.Database
	clients    map[string]*Client // deviceID -> Client
	register   chan *Client
	unregister chan *Client
	broadcast  chan *BroadcastMessage
	mu         sync.RWMutex
}

// BroadcastMessage - сообщение для отправки
type BroadcastMessage struct {
	RecipientID   int64 // 0 = всем
	Data          []byte
	ExcludeDevice string // не отправлять этому устройству
}

// WSMessage - формат WebSocket сообщения
type WSMessage struct {
	Type string          `json:"type"`
	Data json.RawMessage `json:"data"`
}

// NewHub создаёт новый хаб
func NewHub(database *db.Database) *Hub {
	return &Hub{
		db:         database,
		clients:    make(map[string]*Client),
		register:   make(chan *Client),
		unregister: make(chan *Client),
		broadcast:  make(chan *BroadcastMessage, 256),
	}
}

// Run запускает главный цикл хаба
func (h *Hub) Run() {
	for {
		select {
		case client := <-h.register:
			h.mu.Lock()
			if existing, ok := h.clients[client.deviceID]; ok && existing != client {
				// Повторное подключение того же устройства — старое соединение закрываем
				existing.close()
			}
			h.clients[client.deviceID] = client
			h.mu.Unlock()
			log.Printf("📱 Client connected: device=%s user=%d", client.deviceID, client.userID)

		case client := <-h.unregister:
			h.mu.Lock()
			if existing, ok := h.clients[client.deviceID]; ok && existing == client {
				delete(h.clients, client.deviceID)
			}
			h.mu.Unlock()
			client.close()
			log.Printf("📴 Client disconnected: device=%s", client.deviceID)

		case msg := <-h.broadcast:
			h.handleBroadcast(msg)
		}
	}
}

// handleBroadcast отправляет сообщение нужным клиентам
func (h *Hub) handleBroadcast(msg *BroadcastMessage) {
	h.mu.RLock()
	defer h.mu.RUnlock()

	for deviceID, client := range h.clients {
		if deviceID == msg.ExcludeDevice {
			continue
		}
		if msg.RecipientID != 0 && client.userID != msg.RecipientID {
			continue
		}
		client.trySend(msg.Data)
	}
}

// SendToUser отправляет сообщение всем устройствам пользователя
func (h *Hub) SendToUser(userID int64, data []byte, excludeDevice string) {
	h.broadcast <- &BroadcastMessage{
		RecipientID:   userID,
		Data:          data,
		ExcludeDevice: excludeDevice,
	}
}

// SendToDevice отправляет сообщение конкретному устройству
func (h *Hub) SendToDevice(deviceID string, data []byte) {
	h.mu.RLock()
	client, ok := h.clients[deviceID]
	h.mu.RUnlock()

	if ok {
		client.trySend(data)
	}
}

// RegisterClient регистрирует нового клиента
func (h *Hub) RegisterClient(conn *websocket.Conn, userID int64, deviceID string) *Client {
	client := newClient(h, conn, userID, deviceID)
	h.register <- client
	return client
}

// UnregisterClient отключает клиента
func (h *Hub) UnregisterClient(client *Client) {
	h.unregister <- client
}

// GetOnlineDevices возвращает список онлайн устройств пользователя
func (h *Hub) GetOnlineDevices(userID int64) []string {
	h.mu.RLock()
	defer h.mu.RUnlock()

	var devices []string
	for deviceID, client := range h.clients {
		if client.userID == userID {
			devices = append(devices, deviceID)
		}
	}
	return devices
}

// IsDeviceOnline проверяет онлайн ли устройство
func (h *Hub) IsDeviceOnline(deviceID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	_, ok := h.clients[deviceID]
	return ok
}

// DisconnectDevice принудительно разрывает соединение с устройством
func (h *Hub) DisconnectDevice(deviceID string) {
	h.mu.Lock()
	client, ok := h.clients[deviceID]
	if ok {
		delete(h.clients, deviceID)
	}
	h.mu.Unlock()

	if ok {
		client.close()
		client.conn.Close()
	}
}
