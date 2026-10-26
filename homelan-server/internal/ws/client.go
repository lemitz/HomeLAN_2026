package ws

import (
	"encoding/json"
	"errors"
	"log"
	"time"

	"github.com/gorilla/websocket"
	"homelan-server/internal/db"
)

// Формат зашифрованного содержимого: первый байт — версия протокола.
const CryptoVersion = 0x02

const (
	maxContentSize = 64 * 1024
	maxClientIDLen = 64
	syncPageMax    = 200
	historyPageMax = 100
	maxExpiry      = 365 * 24 * time.Hour
)

var allowedContentTypes = map[string]bool{"text": true, "image": true, "file": true}

// Run запускает обработку подключения и блокируется до его закрытия.
func (c *Client) Run() {
	go c.writePump()
	c.readPump()
}

func (c *Client) readPump() {
	defer c.hub.unregister(c)

	c.conn.SetReadLimit(maxMessageSize)
	c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})

	for {
		_, raw, err := c.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure, websocket.CloseAbnormalClosure) {
				log.Printf("WebSocket error (device=%s): %v", c.deviceID, err)
			}
			return
		}
		c.conn.SetReadDeadline(time.Now().Add(pongWait))
		if c.hub.OnActivity != nil {
			c.hub.OnActivity(c.userID, c.deviceID)
		}
		c.handle(raw)
	}
}

func (c *Client) writePump() {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		c.close()
	}()
	for {
		select {
		case <-c.done:
			c.conn.SetWriteDeadline(time.Now().Add(time.Second))
			c.conn.WriteMessage(websocket.CloseMessage, []byte{})
			return
		case msg := <-c.send:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(websocket.TextMessage, msg); err != nil {
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

func (c *Client) reply(typ string, data any) {
	if b := encode(typ, data); b != nil {
		c.enqueue(b)
	}
}

func (c *Client) sendError(code, message string) {
	c.reply("error", map[string]string{"code": code, "message": message})
}

func (c *Client) handle(raw []byte) {
	var env Envelope
	if err := json.Unmarshal(raw, &env); err != nil {
		c.sendError("invalid_format", "invalid message format")
		return
	}
	switch env.Type {
	case "send_message":
		c.handleSendMessage(env.Data)
	case "sync":
		c.handleSync(env.Data)
	case "history":
		c.handleHistory(env.Data)
	case "ack":
		c.handleAck(env.Data)
	case "read":
		c.handleRead(env.Data)
	case "delete":
		c.handleDelete(env.Data)
	case "typing":
		c.handleTyping(env.Data)
	case "ping", "time_sync":
		c.reply("pong", map[string]int64{"server_time": time.Now().Unix()})
	default:
		c.sendError("unknown_type", "unknown message type: "+env.Type)
	}
}

func (c *Client) handleSendMessage(data json.RawMessage) {
	var req struct {
		ClientID         string `json:"client_id"`
		RecipientID      int64  `json:"recipient_id"`
		EncryptedContent []byte `json:"encrypted_content"`
		ContentType      string `json:"content_type"`
		FileID           string `json:"file_id"`
		ExpiresAt        int64  `json:"expires_at"`
	}
	if err := json.Unmarshal(data, &req); err != nil {
		c.sendError("invalid_data", "invalid message data")
		return
	}
	fail := func(code, msg string) {
		c.reply("send_failed", map[string]string{"client_id": req.ClientID, "code": code, "message": msg})
	}

	switch {
	case req.ClientID == "" || len(req.ClientID) > maxClientIDLen:
		fail("invalid_client_id", "client_id is required (max 64 chars)")
		return
	case req.RecipientID == 0 || req.RecipientID == c.userID:
		fail("invalid_recipient", "invalid recipient")
		return
	case !allowedContentTypes[req.ContentType]:
		fail("invalid_content_type", "unsupported content type")
		return
	case len(req.EncryptedContent) < 2 || len(req.EncryptedContent) > maxContentSize:
		fail("invalid_content", "content is empty or too large")
		return
	case req.EncryptedContent[0] != CryptoVersion:
		// Сервер не принимает незашифрованные/устаревшие сообщения.
		fail("unsupported_crypto", "content must be encrypted with protocol v2")
		return
	case (req.ContentType == "text") != (req.FileID == ""):
		fail("invalid_file", "file_id is required for files and forbidden for text")
		return
	}
	if req.ExpiresAt != 0 {
		now := time.Now()
		if req.ExpiresAt <= now.Unix() || req.ExpiresAt > now.Add(maxExpiry).Unix() {
			fail("invalid_expiry", "expires_at out of range")
			return
		}
	}

	recipient, err := c.hub.db.GetUserByID(req.RecipientID)
	if err != nil || recipient == nil {
		fail("user_not_found", "recipient not found")
		return
	}

	msg, dup, err := c.hub.db.InsertMessage(db.NewMessage{
		SenderID:         c.userID,
		SenderDevice:     c.deviceID,
		RecipientID:      req.RecipientID,
		ClientID:         req.ClientID,
		EncryptedContent: req.EncryptedContent,
		ContentType:      req.ContentType,
		FileID:           req.FileID,
		ExpiresAt:        req.ExpiresAt,
	})
	if errors.Is(err, db.ErrFileUnusable) {
		fail("invalid_file", err.Error())
		return
	}
	if err != nil {
		log.Printf("Error creating message: %v", err)
		fail("db_error", "failed to save message")
		return
	}

	c.reply("message_sent", map[string]any{
		"client_id":  msg.ClientID,
		"seq_id":     msg.SeqID,
		"change_seq": msg.ChangeSeq,
		"created_at": msg.CreatedAt,
	})
	if dup {
		// Повтор из outbox: сообщение уже разослано, отдаём только этому устройству.
		c.reply("message", msg)
		return
	}
	c.hub.PublishMessage(msg)
}

func clampLimit(v, max int) int {
	if v <= 0 || v > max {
		return max
	}
	return v
}

func (c *Client) handleSync(data json.RawMessage) {
	var req struct {
		Since int64 `json:"since"`
		Limit int   `json:"limit"`
	}
	if err := json.Unmarshal(data, &req); err != nil || req.Since < 0 {
		c.sendError("invalid_data", "invalid sync request")
		return
	}
	limit := clampLimit(req.Limit, syncPageMax)
	msgs, err := c.hub.db.ChangesSince(c.userID, req.Since, limit+1)
	if err != nil {
		log.Printf("sync error: %v", err)
		c.sendError("db_error", "failed to load changes")
		return
	}
	hasMore := len(msgs) > limit
	if hasMore {
		msgs = msgs[:limit]
	}
	cursor := req.Since
	if len(msgs) > 0 {
		cursor = msgs[len(msgs)-1].ChangeSeq
	} else if !hasMore {
		// Изменений для пользователя нет — можно сдвинуть курсор к глобальному.
		if maxSeq, err := c.hub.db.MaxChangeSeq(); err == nil && maxSeq > cursor {
			cursor = maxSeq
		}
	}
	c.reply("sync_response", map[string]any{
		"messages":    msgs,
		"cursor":      cursor,
		"has_more":    hasMore,
		"server_time": time.Now().Unix(),
	})
}

func (c *Client) handleHistory(data json.RawMessage) {
	var req struct {
		BeforeSeq int64 `json:"before_seq"`
		Limit     int   `json:"limit"`
	}
	if err := json.Unmarshal(data, &req); err != nil || req.BeforeSeq <= 0 {
		c.sendError("invalid_data", "invalid history request")
		return
	}
	limit := clampLimit(req.Limit, historyPageMax)
	msgs, err := c.hub.db.HistoryBefore(c.userID, req.BeforeSeq, limit+1)
	if err != nil {
		c.sendError("db_error", "failed to load history")
		return
	}
	hasMore := len(msgs) > limit
	if hasMore {
		msgs = msgs[:limit]
	}
	c.reply("history_response", map[string]any{
		"before_seq": req.BeforeSeq,
		"messages":   msgs,
		"has_more":   hasMore,
	})
}

func (c *Client) handleAck(data json.RawMessage) {
	var req struct {
		SeqID int64 `json:"seq_id"`
	}
	if json.Unmarshal(data, &req) != nil || req.SeqID <= 0 {
		return
	}
	m, err := c.hub.db.MarkDelivered(req.SeqID, c.userID)
	if err != nil {
		log.Printf("ack error: %v", err)
		return
	}
	c.hub.PublishMessage(m)
}

func (c *Client) handleRead(data json.RawMessage) {
	var req struct {
		UpToSeq int64 `json:"up_to_seq"`
	}
	if json.Unmarshal(data, &req) != nil || req.UpToSeq <= 0 {
		return
	}
	msgs, err := c.hub.db.MarkReadUpTo(c.userID, req.UpToSeq)
	if err != nil {
		log.Printf("read error: %v", err)
		return
	}
	for _, m := range msgs {
		c.hub.PublishMessage(m)
	}
}

func (c *Client) handleDelete(data json.RawMessage) {
	var req struct {
		SeqID int64 `json:"seq_id"`
	}
	if json.Unmarshal(data, &req) != nil || req.SeqID <= 0 {
		c.sendError("invalid_data", "invalid delete request")
		return
	}
	m, fileID, err := c.hub.db.DeleteMessage(req.SeqID, c.userID)
	switch {
	case errors.Is(err, db.ErrNotFound):
		c.sendError("not_found", "message not found")
		return
	case errors.Is(err, db.ErrForbidden):
		c.sendError("forbidden", "cannot delete other's messages")
		return
	case err != nil:
		c.sendError("db_error", "failed to delete message")
		return
	}
	if fileID != "" && c.hub.OnFileReleased != nil {
		c.hub.OnFileReleased(fileID)
	}
	c.hub.PublishMessage(m)
}

func (c *Client) handleTyping(data json.RawMessage) {
	var req struct {
		RecipientID int64 `json:"recipient_id"`
	}
	if json.Unmarshal(data, &req) != nil || req.RecipientID == 0 || req.RecipientID == c.userID {
		return
	}
	c.hub.SendToUser(req.RecipientID, encode("typing", map[string]int64{"user_id": c.userID}), "")
}
