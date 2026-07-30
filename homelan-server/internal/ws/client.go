package ws

import (
	"encoding/json"
	"log"
	"time"

	"github.com/gorilla/websocket"
	"homelan-server/internal/models" // Убедитесь, что импорт models корректен для вашего проекта
)

func (c *Client) ReadPump() {
	defer func() {
		c.hub.UnregisterClient(c)
		c.conn.Close()
	}()

	c.conn.SetReadLimit(maxMessageSize)
	c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))

	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})

	for {
		_, message, err := c.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Printf("WebSocket error: %v", err)
			}
			break
		}

		c.hub.db.UpdateDeviceLastSeen(c.deviceID)
		c.handleMessage(message)
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
		case message, ok := <-c.send:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}

			c.mu.Lock()
			err := c.conn.WriteMessage(websocket.TextMessage, message)
			c.mu.Unlock()

			if err != nil {
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
		log.Printf("Invalid message format: %v", err)
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
	case "time_sync": // NEW
		c.handleTimeSync() // NEW
	default:
		c.sendError("unknown_type", "Unknown message type: "+msg.Type)
	}
}

func (c *Client) handleSendMessage(data json.RawMessage) {
	var req struct {
		RecipientID      int64  `json:"recipient_id"`
		EncryptedContent []byte `json:"encrypted_content"`
		ContentType      string `json:"content_type"`
		FileID           string `json:"file_id,omitempty"`
		ExpiresAt        int64  `json:"expires_at,omitempty"`
	}

	if err := json.Unmarshal(data, &req); err != nil {
		c.sendError("invalid_data", "Invalid message data")
		return
	}

	if req.RecipientID == 0 || req.RecipientID == c.userID {
		c.sendError("invalid_recipient", "Invalid recipient ID")
		return
	}

	recipient, err := c.hub.db.GetUserByID(req.RecipientID)
	if err != nil || recipient == nil {
		c.sendError("user_not_found", "Recipient user not found")
		return
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

	if req.BeforeSeqID > 0 {
		// Пагинация назад (старые сообщения)
		// Примечание: предполагается, что метод GetMessagesBefore реализован в c.hub.db
		messages, err = c.hub.db.GetMessagesBefore(c.userID, req.BeforeSeqID, req.Limit)
	} else {
		// Обычная синхронизация (новые сообщения)
		messages, err = c.hub.db.GetMessagesSince(c.userID, req.SinceSeqID, req.Limit)
	}

	if err != nil {
		log.Printf("Error getting messages: %v", err)
		c.sendError("db_error", "Failed to get messages")
		return
	}

	if len(messages) > 0 && req.BeforeSeqID == 0 {
		// Обновляем курсор только при запросе новых сообщений вперёд
		lastSeq := messages[len(messages)-1].SeqID
		c.hub.db.UpdateSyncCursor(c.deviceID, lastSeq)
	}

	c.sendJSON(map[string]interface{}{
		"type": "sync_response",
		"data": map[string]interface{}{
			"messages":    messages,
			"has_more":    len(messages) == req.Limit,
			"server_time": time.Now().Unix(),
		},
	})
}

func (c *Client) handleAck(data json.RawMessage) {
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

	c.hub.db.SetMessageStatus(message.ID, c.deviceID, "delivered")

	ackData, _ := json.Marshal(map[string]interface{}{
		"type": "status_update",
		"data": map[string]interface{}{
			"seq_id":    req.SeqID,
			"device_id": c.deviceID,
			"status":    "delivered",
		},
	})
	c.hub.SendToUser(message.SenderID, ackData, "")
}

func (c *Client) handleRead(data json.RawMessage) {
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

	c.hub.db.SetMessageStatus(message.ID, c.deviceID, "read")

	readData, _ := json.Marshal(map[string]interface{}{
		"type": "status_update",
		"data": map[string]interface{}{
			"seq_id":    req.SeqID,
			"device_id": c.deviceID,
			"status":    "read",
		},
	})
	c.hub.SendToUser(message.SenderID, readData, "")
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

	typingData, _ := json.Marshal(map[string]interface{}{
		"type": "user_typing",
		"data": map[string]interface{}{
			"user_id": c.userID,
		},
	})

	c.hub.SendToUser(req.RecipientID, typingData, "")
}

// NEW: Обработка запроса синхронизации времени
func (c *Client) handleTimeSync() {
	c.sendJSON(map[string]interface{}{
		"type": "time_sync_response",
		"data": map[string]interface{}{
			"server_time": time.Now().Unix(),
		},
	})
}

// handlePing обновлен: добавлен timestamp
func (c *Client) handlePing() {
	c.sendJSON(map[string]interface{}{
		"type":      "pong",
		"timestamp": time.Now().Unix(), // NEW
		"data": map[string]interface{}{
			"server_time": time.Now().Unix(),
		},
	})
}

func (c *Client) sendJSON(v interface{}) {
	data, err := json.Marshal(v)
	if err != nil {
		return
	}

	select {
	case c.send <- data:
	default:
	}
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