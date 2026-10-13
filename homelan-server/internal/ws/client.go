package ws

import (
	"encoding/json"
	"log"
	"regexp"
	"time"

	"github.com/gorilla/websocket"
	"homelan-server/internal/models"
)

var (
	// content_type: короткий идентификатор вида "encrypted", "encrypted_file", "text"
	contentTypeRe = regexp.MustCompile(`^[a-z][a-z0-9_]{0,31}$`)
	// file_id: hex(16 случайных байт)
	fileIDRe = regexp.MustCompile(`^[0-9a-f]{32}$`)
)

const maxClientIDLen = 64

func (c *Client) ReadPump() {
	defer func() {
		c.hub.UnregisterClient(c)
		c.conn.Close()
	}()

	c.conn.SetReadLimit(maxMessageSize)
	c.conn.SetReadDeadline(time.Now().Add(pongWait))

	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})

	for {
		_, message, err := c.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure, websocket.CloseNormalClosure) {
				log.Printf("WebSocket error: %v", err)
			}
			break
		}

		c.touch()
		c.handleMessage(message)
	}
}

// touch обновляет last_seen устройства и пользователя, но не чаще раза в
// lastSeenUpdateInterval. Активность пользователя учитывается Dead Man's Switch,
// поэтому важно обновлять её не только при подключении, но и при работе.
func (c *Client) touch() {
	if c.hub.db == nil {
		return
	}
	now := time.Now()
	if now.Sub(c.lastSeenUpdate) < lastSeenUpdateInterval {
		return
	}
	c.lastSeenUpdate = now
	if err := c.hub.db.UpdateDeviceLastSeen(c.deviceID); err != nil {
		log.Printf("UpdateDeviceLastSeen error: %v", err)
	}
	if err := c.hub.db.UpdateUserLastSeen(c.userID); err != nil {
		log.Printf("UpdateUserLastSeen error: %v", err)
	}
}

func (c *Client) WritePump() {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		c.conn.Close()
	}()

	for {
		select {
		case <-c.done:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			c.conn.WriteMessage(websocket.CloseMessage,
				websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""))
			return

		case message := <-c.send:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(websocket.TextMessage, message); err != nil {
				return
			}

		case <-ticker.C:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

func (c *Client) handleMessage(data []byte) {
	var msg WSMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		c.sendError("invalid_format", "Invalid message format")
		return
	}

	switch msg.Type {
	case "send_message":
		c.handleSendMessage(msg.Data)
	case "sync":
		c.handleSync(msg.Data)
	case "ack":
		c.handleAck(msg.Data)
	case "read":
		c.handleRead(msg.Data)
	case "delete":
		c.handleDelete(msg.Data)
	case "typing":
		c.handleTyping(msg.Data)
	case "ping":
		c.handlePing()
	case "time_sync":
		c.handleTimeSync()
	default:
		c.sendError("unknown_type", "Unknown message type")
	}
}

func (c *Client) handleSendMessage(data json.RawMessage) {
	var req struct {
		RecipientID      int64  `json:"recipient_id"`
		EncryptedContent []byte `json:"encrypted_content"`
		ContentType      string `json:"content_type"`
		FileID           string `json:"file_id,omitempty"`
		ExpiresAt        int64  `json:"expires_at,omitempty"`
		// ClientID — произвольный идентификатор, который клиент присвоил сообщению
		// до отправки. Сервер возвращает его в message_sent, чтобы клиент мог
		// однозначно сопоставить seq_id с нужным локальным сообщением.
		ClientID string `json:"client_id,omitempty"`
	}

	if err := json.Unmarshal(data, &req); err != nil {
		c.sendError("invalid_data", "Invalid message data")
		return
	}

	if req.RecipientID == 0 || req.RecipientID == c.userID {
		c.sendError("invalid_recipient", "Invalid recipient ID")
		return
	}
	if len(req.EncryptedContent) == 0 {
		c.sendError("invalid_data", "Empty message content")
		return
	}
	if !contentTypeRe.MatchString(req.ContentType) {
		c.sendError("invalid_data", "Invalid content_type")
		return
	}
	if len(req.ClientID) > maxClientIDLen {
		c.sendError("invalid_data", "client_id too long")
		return
	}
	if req.ExpiresAt < 0 || (req.ExpiresAt > 0 && req.ExpiresAt <= time.Now().Unix()) {
		c.sendError("invalid_data", "expires_at must be in the future")
		return
	}

	recipient, err := c.hub.db.GetUserByID(req.RecipientID)
	if err != nil || recipient == nil {
		c.sendError("user_not_found", "Recipient user not found")
		return
	}

	if req.FileID != "" {
		if !fileIDRe.MatchString(req.FileID) {
			c.sendError("invalid_data", "Invalid file_id")
			return
		}
		file, err := c.hub.db.GetFileByID(req.FileID)
		if err != nil || file == nil || file.IsDeleted {
			c.sendError("file_not_found", "File not found")
			return
		}
		if file.UploaderID != c.userID {
			c.sendError("forbidden", "File belongs to another user")
			return
		}
	}

	message, err := c.hub.db.CreateMessage(
		c.userID,
		req.RecipientID,
		req.EncryptedContent,
		req.ContentType,
		req.FileID,
		req.ExpiresAt,
	)
	if err != nil {
		log.Printf("Error creating message: %v", err)
		c.sendError("db_error", "Failed to save message")
		return
	}

	c.sendJSON(map[string]interface{}{
		"type": "message_sent",
		"data": map[string]interface{}{
			"seq_id":     message.SeqID,
			"created_at": message.CreatedAt,
			"client_id":  req.ClientID,
		},
	})

	msgData, _ := json.Marshal(map[string]interface{}{
		"type": "new_message",
		"data": map[string]interface{}{
			"seq_id":            message.SeqID,
			"sender_id":         message.SenderID,
			"recipient_id":      message.RecipientID,
			"encrypted_content": message.EncryptedContent,
			"content_type":      message.ContentType,
			"file_id":           message.FileID,
			"created_at":        message.CreatedAt,
			"expires_at":        message.ExpiresAt,
		},
	})

	c.hub.SendToUser(req.RecipientID, msgData, "")
	c.hub.SendToUser(c.userID, msgData, c.deviceID)

	log.Printf("📨 Message sent: seq=%d from=%d to=%d", message.SeqID, c.userID, req.RecipientID)
}

func (c *Client) handleSync(data json.RawMessage) {
	var req struct {
		SinceSeqID  int64 `json:"since_seq_id"`
		BeforeSeqID int64 `json:"before_seq_id"`
		Limit       int   `json:"limit,omitempty"`
	}

	if err := json.Unmarshal(data, &req); err != nil {
		c.sendError("invalid_data", "Invalid sync request")
		return
	}

	if req.Limit <= 0 || req.Limit > 100 {
		req.Limit = 100
	}

	var messages []*models.Message
	var err error
	direction := "forward"

	if req.BeforeSeqID > 0 {
		// Пагинация назад (старые сообщения)
		direction = "backward"
		messages, err = c.hub.db.GetMessagesBefore(c.userID, req.BeforeSeqID, req.Limit)
	} else {
		// Обычная синхронизация (новые сообщения + tombstone удалённых)
		messages, err = c.hub.db.GetMessagesSince(c.userID, req.SinceSeqID, req.Limit)
	}

	if err != nil {
		log.Printf("Error getting messages: %v", err)
		c.sendError("db_error", "Failed to get messages")
		return
	}

	if messages == nil {
		messages = []*models.Message{}
	}

	if len(messages) > 0 && direction == "forward" {
		// Обновляем курсор только при запросе новых сообщений вперёд
		lastSeq := messages[len(messages)-1].SeqID
		c.hub.db.UpdateSyncCursor(c.deviceID, lastSeq)
	}

	c.sendJSON(map[string]interface{}{
		"type": "sync_response",
		"data": map[string]interface{}{
			"messages":    messages,
			"has_more":    len(messages) == req.Limit,
			"direction":   direction,
			"server_time": time.Now().Unix(),
		},
	})
}

// statusUpdate обрабатывает ack/read: статус может ставить только получатель сообщения.
func (c *Client) statusUpdate(data json.RawMessage, status string) {
	var req struct {
		SeqID int64 `json:"seq_id"`
	}

	if err := json.Unmarshal(data, &req); err != nil {
		return
	}

	message, err := c.hub.db.GetMessageBySeqID(req.SeqID)
	if err != nil || message == nil || message.IsDeleted {
		return
	}
	if message.RecipientID != c.userID {
		// Отправитель (или кто-то посторонний) не может подтверждать доставку/прочтение
		return
	}

	if err := c.hub.db.SetMessageStatus(message.ID, c.deviceID, status); err != nil {
		log.Printf("SetMessageStatus error: %v", err)
		return
	}

	payload, _ := json.Marshal(map[string]interface{}{
		"type": "status_update",
		"data": map[string]interface{}{
			"seq_id":    req.SeqID,
			"device_id": c.deviceID,
			"status":    status,
		},
	})
	c.hub.SendToUser(message.SenderID, payload, "")
}

func (c *Client) handleAck(data json.RawMessage) {
	c.statusUpdate(data, "delivered")
}

func (c *Client) handleRead(data json.RawMessage) {
	c.statusUpdate(data, "read")
}

func (c *Client) handleDelete(data json.RawMessage) {
	var req struct {
		SeqID int64 `json:"seq_id"`
	}

	if err := json.Unmarshal(data, &req); err != nil {
		return
	}

	message, err := c.hub.db.GetMessageBySeqID(req.SeqID)
	if err != nil || message == nil {
		return
	}

	if message.SenderID != c.userID {
		c.sendError("forbidden", "Cannot delete other's messages")
		return
	}

	if message.IsDeleted {
		return
	}

	if err := c.hub.db.DeleteMessage(req.SeqID); err != nil {
		c.sendError("db_error", "Failed to delete message")
		return
	}

	deleteData, _ := json.Marshal(map[string]interface{}{
		"type": "message_deleted",
		"data": map[string]interface{}{
			"seq_id": req.SeqID,
		},
	})

	c.hub.SendToUser(c.userID, deleteData, "")
	c.hub.SendToUser(message.RecipientID, deleteData, "")

	log.Printf("🗑️ Message deleted: seq=%d by=%d", req.SeqID, c.userID)
}

func (c *Client) handleTyping(data json.RawMessage) {
	var req struct {
		RecipientID int64 `json:"recipient_id"`
	}

	if err := json.Unmarshal(data, &req); err != nil {
		return
	}
	if req.RecipientID == 0 || req.RecipientID == c.userID {
		return
	}

	typingData, _ := json.Marshal(map[string]interface{}{
		"type": "user_typing",
		"data": map[string]interface{}{
			"user_id": c.userID,
		},
	})

	c.hub.SendToUser(req.RecipientID, typingData, "")
}

// handleTimeSync — ответ на запрос синхронизации времени
func (c *Client) handleTimeSync() {
	c.sendJSON(map[string]interface{}{
		"type": "time_sync_response",
		"data": map[string]interface{}{
			"server_time": time.Now().Unix(),
		},
	})
}

func (c *Client) handlePing() {
	now := time.Now().Unix()
	c.sendJSON(map[string]interface{}{
		"type":      "pong",
		"timestamp": now,
		"data": map[string]interface{}{
			"server_time": now,
		},
	})
}

func (c *Client) sendJSON(v interface{}) {
	data, err := json.Marshal(v)
	if err != nil {
		return
	}
	c.trySend(data)
}

func (c *Client) sendError(code, message string) {
	c.sendJSON(map[string]interface{}{
		"type": "error",
		"data": map[string]interface{}{
			"code":    code,
			"message": message,
		},
	})
}
