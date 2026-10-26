package models

// User — пользователь системы.
type User struct {
	ID           int64  `json:"id"`
	Username     string `json:"username"`
	PasswordHash string `json:"-"`
	// PublicKey — публичный identity-ключ X25519 пользователя (32 байта).
	// Один на все устройства пользователя, задаётся при регистрации.
	PublicKey []byte `json:"public_key"`
	CreatedAt int64  `json:"created_at"`
	LastSeen  int64  `json:"last_seen"`
	IsAdmin   bool   `json:"is_admin"`
}

// Device — устройство пользователя.
type Device struct {
	ID         int64  `json:"-"`
	UserID     int64  `json:"user_id"`
	DeviceID   string `json:"device_id"`
	DeviceName string `json:"device_name"`
	DeviceType string `json:"device_type"`
	CreatedAt  int64  `json:"created_at"`
	LastSeen   int64  `json:"last_seen"`
	IsRevoked  bool   `json:"is_revoked"`
}

// Message — сообщение. SeqID — постоянный идентификатор сообщения,
// ChangeSeq — монотонный номер последнего изменения (новое сообщение,
// статус, удаление). Синхронизация идёт по ChangeSeq.
type Message struct {
	SeqID            int64  `json:"seq_id"`
	ChangeSeq        int64  `json:"change_seq"`
	SenderID         int64  `json:"sender_id"`
	SenderDevice     string `json:"-"`
	RecipientID      int64  `json:"recipient_id"`
	ClientID         string `json:"client_id"`
	EncryptedContent []byte `json:"encrypted_content"`
	ContentType      string `json:"content_type"`
	FileID           string `json:"file_id,omitempty"`
	CreatedAt        int64  `json:"created_at"`
	ExpiresAt        int64  `json:"expires_at,omitempty"`
	DeliveredAt      int64  `json:"delivered_at,omitempty"`
	ReadAt           int64  `json:"read_at,omitempty"`
	IsDeleted        bool   `json:"is_deleted"`
	DeletedAt        int64  `json:"deleted_at,omitempty"`
}

// File — метаданные загруженного (зашифрованного клиентом) файла.
// Имя и MIME-тип сервер не знает: они лежат в зашифрованном сообщении.
type File struct {
	ID          string `json:"file_id"`
	UploaderID  int64  `json:"uploader_id"`
	FileSize    int64  `json:"file_size"`
	StoragePath string `json:"-"`
	CreatedAt   int64  `json:"created_at"`
	ExpiresAt   int64  `json:"expires_at,omitempty"`
	Attached    bool   `json:"-"`
	IsDeleted   bool   `json:"is_deleted"`
}

// Session — сессия устройства. Хранится только SHA-256 от токена.
type Session struct {
	ID        int64
	TokenHash string
	UserID    int64
	DeviceID  string
	CreatedAt int64
	ExpiresAt int64
	LastUsed  int64
	IsRevoked bool
}
