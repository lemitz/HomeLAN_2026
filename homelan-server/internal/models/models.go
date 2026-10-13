package models

// User - пользователь системы
type User struct {
	ID           int64  `json:"id"`
	Username     string `json:"username"`
	PasswordHash string `json:"-"` // не отправляем в JSON
	PublicKey    []byte `json:"public_key,omitempty"`
	CreatedAt    int64  `json:"created_at"`
	LastSeen     int64  `json:"last_seen"`
	IsAdmin      bool   `json:"is_admin"`
}

// Device - устройство пользователя
type Device struct {
	ID         int64  `json:"id"`
	UserID     int64  `json:"user_id"`
	DeviceID   string `json:"device_id"`
	DeviceName string `json:"device_name"`
	DeviceType string `json:"device_type"` // "android", "windows"
	PublicKey  []byte `json:"public_key"`
	CreatedAt  int64  `json:"created_at"`
	LastSeen   int64  `json:"last_seen"`
	IsRevoked  bool   `json:"is_revoked"`
}

// Message - сообщение
type Message struct {
	ID               int64  `json:"id"`
	SeqID            int64  `json:"seq_id"`
	SenderID         int64  `json:"sender_id"`
	RecipientID      int64  `json:"recipient_id"`
	EncryptedContent []byte `json:"encrypted_content"`
	ContentType      string `json:"content_type"` // "text", "image", "file"
	FileID           string `json:"file_id,omitempty"`
	CreatedAt        int64  `json:"created_at"`
	ExpiresAt        int64  `json:"expires_at,omitempty"`
	IsDeleted        bool   `json:"is_deleted"`
	DeletedAt        int64  `json:"deleted_at,omitempty"`
}

// MessageStatus - статус доставки сообщения на устройство
type MessageStatus struct {
	ID        int64  `json:"id"`
	MessageID int64  `json:"message_id"`
	DeviceID  string `json:"device_id"`
	Status    string `json:"status"` // "sent", "delivered", "read"
	UpdatedAt int64  `json:"updated_at"`
}

// File - метаданные файла
type File struct {
	ID                string `json:"id"`
	UploaderID        int64  `json:"uploader_id"`
	FileNameEncrypted []byte `json:"file_name_encrypted"`
	FileSize          int64  `json:"file_size"`
	MimeType          string `json:"mime_type"`
	StoragePath       string `json:"-"` // не отправляем
	CreatedAt         int64  `json:"created_at"`
	ExpiresAt         int64  `json:"expires_at,omitempty"`
	IsDeleted         bool   `json:"is_deleted"`
}

// SyncCursor - позиция синхронизации устройства
type SyncCursor struct {
	DeviceID  string `json:"device_id"`
	LastSeqID int64  `json:"last_seq_id"`
	UpdatedAt int64  `json:"updated_at"`
}

// Session - сессия пользователя
type Session struct {
	ID        int64  `json:"id"`
	TokenHash string `json:"-"` // хэш токена наружу не отдаём
	UserID    int64  `json:"user_id"`
	DeviceID  string `json:"device_id"`
	CreatedAt int64  `json:"created_at"`
	ExpiresAt int64  `json:"expires_at"`
	IsRevoked bool   `json:"is_revoked"`
	// DeviceRevoked = true, если устройство сессии отозвано или удалено.
	// Такая сессия недействительна независимо от IsRevoked.
	DeviceRevoked bool `json:"-"`
}
