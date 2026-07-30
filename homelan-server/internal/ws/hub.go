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

	// Максимальный размер сообщения (1MB)
	maxMessageSize = 1024 * 1024
)

// Client - подключённый клиент
type Client struct {
	hub      *Hub
	conn     *websocket.Conn
	send     chan []byte
	userID   int64
	deviceID string
	mu       sync.Mutex
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
				close(existing.send)
			}
			h.clients[client.deviceID] = client
			h.mu.Unlock()
			log.Printf("📱 Client connected: device=%s user=%d", client.deviceID, client.userID)

		case client := <-h.unregister:
			h.mu.Lock()
			if existing, ok := h.clients[client.deviceID]; ok && existing == client {
				delete(h.clients, client.deviceID)
				close(client.send)
			}
			h.mu.Unlock()
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

	if msg.RecipientID == 0 {
		// Всем (кроме исключённого)
		for deviceID, client := range h.clients {
			if deviceID != msg.ExcludeDevice {
				select {
				case client.send <- msg.Data:
				default:
					// Буфер полон, пропускаем
				}
			}
		}
	} else {
		// Конкретному пользователю (все его устройства)
		for deviceID, client := range h.clients {
			if client.userID == msg.RecipientID && deviceID != msg.ExcludeDevice {
				select {
				case client.send <- msg.Data:
				default:
				}
			}
		}
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
		select {
		case client.send <- data:
		default:
		}
	}
}

// RegisterClient регистрирует нового клиента
func (h *Hub) RegisterClient(conn *websocket.Conn, userID int64, deviceID string) *Client {
	client := &Client{
		hub:      h,
		conn:     conn,
		send:     make(chan []byte, 256),
		userID:   userID,
		deviceID: deviceID,
	}

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
		close(client.send)
		client.conn.Close()
	}
	h.mu.Unlock()
}
