package db

import (
	"database/sql"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	_ "github.com/mutecomm/go-sqlcipher/v4"
	"golang.org/x/crypto/bcrypt"
	"homelan-server/internal/models"
)

type Database struct {
	conn *sql.DB
	mu   sync.Mutex
}

// New открывает зашифрованную БД
func New(dbPath string, encryptionKey []byte) (*Database, error) {
	dir := filepath.Dir(dbPath)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, fmt.Errorf("failed to create db directory: %w", err)
	}

	// SQLCipher DSN с ключом
	keyHex := hex.EncodeToString(encryptionKey)
	dsn := fmt.Sprintf("%s?_pragma_key=x'%s'&_pragma_cipher_page_size=4096", dbPath, keyHex)

	// Используем драйвер sqlite3 (который предоставляет go-sqlcipher)
	conn, err := sql.Open("sqlite3", dsn)
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	// Проверяем что ключ правильный
	if err := conn.Ping(); err != nil {
		conn.Close()
		return nil, fmt.Errorf("failed to open database (wrong key?): %w", err)
	}

	// Проверяем что можем читать (валидация ключа)
	var count int
	err = conn.QueryRow("SELECT count(*) FROM sqlite_master").Scan(&count)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("database key verification failed: %w", err)
	}

	// Настройки производительности
	_, err = conn.Exec(`
		PRAGMA journal_mode=WAL;
		PRAGMA busy_timeout=5000;
		PRAGMA synchronous=NORMAL;
		PRAGMA cache_size=-64000;
		PRAGMA foreign_keys=ON;
	`)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("failed to set pragmas: %w", err)
	}

	db := &Database{conn: conn}

	if err := db.initSchema(); err != nil {
		conn.Close()
		return nil, fmt.Errorf("failed to init schema: %w", err)
	}

	return db, nil
}

func (db *Database) Close() error {
	return db.conn.Close()
}

func (db *Database) initSchema() error {
	schema := `
	CREATE TABLE IF NOT EXISTS users (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		username TEXT UNIQUE NOT NULL,
		password_hash TEXT NOT NULL,
		public_key BLOB,
		created_at INTEGER NOT NULL,
		last_seen INTEGER NOT NULL,
		is_admin INTEGER DEFAULT 0
	);

	CREATE TABLE IF NOT EXISTS devices (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		user_id INTEGER NOT NULL,
		device_id TEXT UNIQUE NOT NULL,
		device_name TEXT NOT NULL,
		device_type TEXT NOT NULL,
		public_key BLOB,
		created_at INTEGER NOT NULL,
		last_seen INTEGER NOT NULL,
		is_revoked INTEGER DEFAULT 0,
		FOREIGN KEY (user_id) REFERENCES users(id)
	);

	CREATE TABLE IF NOT EXISTS messages (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		seq_id INTEGER UNIQUE NOT NULL,
		sender_id INTEGER NOT NULL,
		recipient_id INTEGER NOT NULL,
		encrypted_content BLOB NOT NULL,
		content_type TEXT NOT NULL,
		file_id TEXT,
		created_at INTEGER NOT NULL,
		expires_at INTEGER,
		is_deleted INTEGER DEFAULT 0,
		deleted_at INTEGER,
		FOREIGN KEY (sender_id) REFERENCES users(id),
		FOREIGN KEY (recipient_id) REFERENCES users(id)
	);

	CREATE TABLE IF NOT EXISTS message_status (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		message_id INTEGER NOT NULL,
		device_id TEXT NOT NULL,
		status TEXT NOT NULL,
		updated_at INTEGER NOT NULL,
		FOREIGN KEY (message_id) REFERENCES messages(id),
		UNIQUE(message_id, device_id)
	);

	CREATE TABLE IF NOT EXISTS files (
		id TEXT PRIMARY KEY,
		uploader_id INTEGER NOT NULL,
		file_name_encrypted BLOB NOT NULL,
		file_size INTEGER NOT NULL,
		mime_type TEXT,
		storage_path TEXT NOT NULL,
		created_at INTEGER NOT NULL,
		expires_at INTEGER,
		is_deleted INTEGER DEFAULT 0,
		FOREIGN KEY (uploader_id) REFERENCES users(id)
	);

	CREATE TABLE IF NOT EXISTS sync_cursors (
		device_id TEXT PRIMARY KEY,
		last_seq_id INTEGER NOT NULL DEFAULT 0,
		updated_at INTEGER NOT NULL
	);

	CREATE TABLE IF NOT EXISTS sessions (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		token_hash TEXT UNIQUE NOT NULL,
		user_id INTEGER NOT NULL,
		device_id TEXT NOT NULL,
		created_at INTEGER NOT NULL,
		expires_at INTEGER NOT NULL,
		is_revoked INTEGER DEFAULT 0,
		FOREIGN KEY (user_id) REFERENCES users(id)
	);

	CREATE INDEX IF NOT EXISTS idx_messages_seq ON messages(seq_id);
	CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender_id);
	CREATE INDEX IF NOT EXISTS idx_messages_recipient ON messages(recipient_id);
	CREATE INDEX IF NOT EXISTS idx_devices_user ON devices(user_id);
	CREATE INDEX IF NOT EXISTS idx_sessions_token ON sessions(token_hash);
	`

	_, err := db.conn.Exec(schema)
	return err
}

// ============ USER METHODS ============

func (db *Database) CreateUser(username, password string, isAdmin bool) (*models.User, error) {
	now := time.Now().Unix()
	adminInt := 0
	if isAdmin {
		adminInt = 1
	}

	hashedBytes, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return nil, fmt.Errorf("failed to hash password: %w", err)
	}
	passwordHash := string(hashedBytes)

	result, err := db.conn.Exec(
		`INSERT INTO users (username, password_hash, created_at, last_seen, is_admin) 
		 VALUES (?, ?, ?, ?, ?)`,
		username, passwordHash, now, now, adminInt,
	)
	if err != nil {
		return nil, err
	}

	id, _ := result.LastInsertId()
	return &models.User{
		ID:           id,
		Username:     username,
		PasswordHash: passwordHash,
		CreatedAt:    now,
		LastSeen:     now,
		IsAdmin:      isAdmin,
	}, nil
}

func (db *Database) GetUserByUsername(username string) (*models.User, error) {
	var user models.User
	var isAdmin int
	var publicKey []byte

	err := db.conn.QueryRow(
		`SELECT id, username, password_hash, public_key, created_at, last_seen, is_admin 
		 FROM users WHERE username = ?`,
		username,
	).Scan(&user.ID, &user.Username, &user.PasswordHash, &publicKey,
		&user.CreatedAt, &user.LastSeen, &isAdmin)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	user.PublicKey = publicKey
	user.IsAdmin = isAdmin == 1
	return &user, nil
}

func (db *Database) GetUserByID(id int64) (*models.User, error) {
	var user models.User
	var isAdmin int
	var publicKey []byte

	err := db.conn.QueryRow(
		`SELECT id, username, password_hash, public_key, created_at, last_seen, is_admin 
		 FROM users WHERE id = ?`,
		id,
	).Scan(&user.ID, &user.Username, &user.PasswordHash, &publicKey,
		&user.CreatedAt, &user.LastSeen, &isAdmin)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	user.PublicKey = publicKey
	user.IsAdmin = isAdmin == 1
	return &user, nil
}

func (db *Database) UpdateUserLastSeen(userID int64) error {
	_, err := db.conn.Exec(
		`UPDATE users SET last_seen = ? WHERE id = ?`,
		time.Now().Unix(), userID,
	)
	return err
}

func (db *Database) UpdateUserPublicKey(userID int64, publicKey []byte) error {
	_, err := db.conn.Exec(
		`UPDATE users SET public_key = ? WHERE id = ?`,
		publicKey, userID,
	)
	return err
}

func (db *Database) GetAdmin() (*models.User, error) {
	var user models.User
	var isAdmin int
	var publicKey []byte

	err := db.conn.QueryRow(
		`SELECT id, username, password_hash, public_key, created_at, last_seen, is_admin 
		 FROM users WHERE is_admin = 1 LIMIT 1`,
	).Scan(&user.ID, &user.Username, &user.PasswordHash, &publicKey,
		&user.CreatedAt, &user.LastSeen, &isAdmin)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	user.PublicKey = publicKey
	user.IsAdmin = true
	return &user, nil
}

// ============ DEVICE METHODS ============

// CreateOrUpdateDevice - создаёт новый девайс или обновляет существующий
func (db *Database) CreateOrUpdateDevice(userID int64, deviceID, deviceName, deviceType string, publicKey []byte) (*models.Device, error) {
	now := time.Now().Unix()

	if publicKey == nil {
		publicKey = []byte{}
	}

	// Проверяем существует ли девайс
	existing, err := db.GetDeviceByID(deviceID)
	if err != nil {
		return nil, err
	}

	if existing != nil {
		// Девайс существует — обновляем
		_, err := db.conn.Exec(
			`UPDATE devices SET user_id = ?, device_name = ?, device_type = ?, public_key = ?, last_seen = ?, is_revoked = 0
			 WHERE device_id = ?`,
			userID, deviceName, deviceType, publicKey, now, deviceID,
		)
		if err != nil {
			return nil, err
		}

		existing.UserID = userID
		existing.DeviceName = deviceName
		existing.DeviceType = deviceType
		existing.PublicKey = publicKey
		existing.LastSeen = now
		existing.IsRevoked = false
		return existing, nil
	}

	// Девайс не существует — создаём новый
	result, err := db.conn.Exec(
		`INSERT INTO devices (user_id, device_id, device_name, device_type, public_key, created_at, last_seen, is_revoked)
		 VALUES (?, ?, ?, ?, ?, ?, ?, 0)`,
		userID, deviceID, deviceName, deviceType, publicKey, now, now,
	)
	if err != nil {
		return nil, err
	}

	id, _ := result.LastInsertId()
	return &models.Device{
		ID:         id,
		UserID:     userID,
		DeviceID:   deviceID,
		DeviceName: deviceName,
		DeviceType: deviceType,
		PublicKey:  publicKey,
		CreatedAt:  now,
		LastSeen:   now,
		IsRevoked:  false,
	}, nil
}

// CreateDevice - оставляем для совместимости, но теперь вызывает CreateOrUpdateDevice
func (db *Database) CreateDevice(userID int64, deviceID, deviceName, deviceType string, publicKey []byte) (*models.Device, error) {
	return db.CreateOrUpdateDevice(userID, deviceID, deviceName, deviceType, publicKey)
}

func (db *Database) GetDeviceByID(deviceID string) (*models.Device, error) {
	var device models.Device
	var isRevoked int

	err := db.conn.QueryRow(
		`SELECT id, user_id, device_id, device_name, device_type, public_key, created_at, last_seen, is_revoked
		 FROM devices WHERE device_id = ?`,
		deviceID,
	).Scan(&device.ID, &device.UserID, &device.DeviceID, &device.DeviceName,
		&device.DeviceType, &device.PublicKey, &device.CreatedAt, &device.LastSeen, &isRevoked)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	device.IsRevoked = isRevoked == 1
	return &device, nil
}

func (db *Database) GetUserDevices(userID int64) ([]*models.Device, error) {
	rows, err := db.conn.Query(
		`SELECT id, user_id, device_id, device_name, device_type, public_key, created_at, last_seen, is_revoked
		 FROM devices WHERE user_id = ? AND is_revoked = 0`,
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var devices []*models.Device
	for rows.Next() {
		var d models.Device
		var isRevoked int
		err := rows.Scan(&d.ID, &d.UserID, &d.DeviceID, &d.DeviceName,
			&d.DeviceType, &d.PublicKey, &d.CreatedAt, &d.LastSeen, &isRevoked)
		if err != nil {
			return nil, err
		}
		d.IsRevoked = isRevoked == 1
		devices = append(devices, &d)
	}

	return devices, nil
}

func (db *Database) UpdateDeviceLastSeen(deviceID string) error {
	_, err := db.conn.Exec(
		`UPDATE devices SET last_seen = ? WHERE device_id = ?`,
		time.Now().Unix(), deviceID,
	)
	return err
}

func (db *Database) RevokeDevice(deviceID string) error {
	_, err := db.conn.Exec(
		`UPDATE devices SET is_revoked = 1 WHERE device_id = ?`,
		deviceID,
	)
	return err
}

// ============ MESSAGE METHODS ============

func (db *Database) GetNextSeqID() (int64, error) {
	var maxSeq sql.NullInt64
	err := db.conn.QueryRow(`SELECT MAX(seq_id) FROM messages`).Scan(&maxSeq)
	if err != nil {
		return 0, err
	}
	if !maxSeq.Valid {
		return 1, nil
	}
	return maxSeq.Int64 + 1, nil
}

func (db *Database) CreateMessage(senderID, recipientID int64, encryptedContent []byte, contentType string, fileID string, expiresAt int64) (*models.Message, error) {
	db.mu.Lock()
	defer db.mu.Unlock()

	seqID, err := db.GetNextSeqID()
	if err != nil {
		return nil, err
	}

	now := time.Now().Unix()

	var fileIDPtr interface{}
	if fileID != "" {
		fileIDPtr = fileID
	}

	var expiresAtPtr interface{}
	if expiresAt > 0 {
		expiresAtPtr = expiresAt
	}

	result, err := db.conn.Exec(
		`INSERT INTO messages (seq_id, sender_id, recipient_id, encrypted_content, content_type, file_id, created_at, expires_at, is_deleted)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)`,
		seqID, senderID, recipientID, encryptedContent, contentType, fileIDPtr, now, expiresAtPtr,
	)
	if err != nil {
		return nil, err
	}

	id, _ := result.LastInsertId()
	return &models.Message{
		ID:               id,
		SeqID:            seqID,
		SenderID:         senderID,
		RecipientID:      recipientID,
		EncryptedContent: encryptedContent,
		ContentType:      contentType,
		FileID:           fileID,
		CreatedAt:        now,
		ExpiresAt:        expiresAt,
	}, nil
}

// GetMessagesSince - получает сообщения для юзера с фильтрацией (вперёд)
func (db *Database) GetMessagesSince(userID int64, sinceSeqID int64, limit int) ([]*models.Message, error) {
	rows, err := db.conn.Query(
		`SELECT id, seq_id, sender_id, recipient_id, encrypted_content, content_type, file_id, created_at, expires_at, is_deleted, deleted_at
		 FROM messages 
		 WHERE (sender_id = ? OR recipient_id = ?) 
		   AND seq_id > ? 
		   AND is_deleted = 0
		 ORDER BY seq_id ASC
		 LIMIT ?`,
		userID, userID, sinceSeqID, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var messages []*models.Message
	for rows.Next() {
		var m models.Message
		var fileID sql.NullString
		var expiresAt, deletedAt sql.NullInt64
		var isDeleted int

		err := rows.Scan(&m.ID, &m.SeqID, &m.SenderID, &m.RecipientID,
			&m.EncryptedContent, &m.ContentType, &fileID, &m.CreatedAt,
			&expiresAt, &isDeleted, &deletedAt)
		if err != nil {
			return nil, err
		}

		if fileID.Valid {
			m.FileID = fileID.String
		}
		if expiresAt.Valid {
			m.ExpiresAt = expiresAt.Int64
		}
		if deletedAt.Valid {
			m.DeletedAt = deletedAt.Int64
		}
		m.IsDeleted = isDeleted == 1

		messages = append(messages, &m)
	}

	return messages, nil
}

// GetMessagesBefore - получает старые сообщения для пагинации (назад)
func (db *Database) GetMessagesBefore(userID int64, beforeSeqID int64, limit int) ([]*models.Message, error) {
	rows, err := db.conn.Query(`
		SELECT id, seq_id, sender_id, recipient_id, encrypted_content, content_type, 
		       file_id, created_at, expires_at, is_deleted, deleted_at
		FROM messages
		WHERE (sender_id = ? OR recipient_id = ?) 
		  AND seq_id < ?
		  AND is_deleted = 0
		ORDER BY seq_id DESC
		LIMIT ?
	`, userID, userID, beforeSeqID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	messages := []*models.Message{}

	for rows.Next() {
		m := &models.Message{}
		var fileID sql.NullString
		var expiresAt, deletedAt sql.NullInt64
		var isDeleted int

		if err := rows.Scan(&m.ID, &m.SeqID, &m.SenderID, &m.RecipientID, &m.EncryptedContent,
			&m.ContentType, &fileID, &m.CreatedAt, &expiresAt, &isDeleted, &deletedAt); err != nil {
			return nil, err
		}

		if fileID.Valid {
			m.FileID = fileID.String
		}
		if expiresAt.Valid {
			m.ExpiresAt = expiresAt.Int64
		}
		if deletedAt.Valid {
			m.DeletedAt = deletedAt.Int64
		}

		m.IsDeleted = isDeleted == 1

		messages = append(messages, m)
	}

	return messages, nil
}

func (db *Database) GetMessageBySeqID(seqID int64) (*models.Message, error) {
	var m models.Message
	var fileID sql.NullString
	var expiresAt, deletedAt sql.NullInt64
	var isDeleted int

	err := db.conn.QueryRow(
		`SELECT id, seq_id, sender_id, recipient_id, encrypted_content, content_type, file_id, created_at, expires_at, is_deleted, deleted_at
		 FROM messages WHERE seq_id = ?`,
		seqID,
	).Scan(&m.ID, &m.SeqID, &m.SenderID, &m.RecipientID,
		&m.EncryptedContent, &m.ContentType, &fileID, &m.CreatedAt,
		&expiresAt, &isDeleted, &deletedAt)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	if fileID.Valid {
		m.FileID = fileID.String
	}
	if expiresAt.Valid {
		m.ExpiresAt = expiresAt.Int64
	}
	if deletedAt.Valid {
		m.DeletedAt = deletedAt.Int64
	}
	m.IsDeleted = isDeleted == 1

	return &m, nil
}

func (db *Database) DeleteMessage(seqID int64) error {
	now := time.Now().Unix()
	_, err := db.conn.Exec(
		`UPDATE messages SET is_deleted = 1, deleted_at = ?, encrypted_content = X'' WHERE seq_id = ?`,
		now, seqID,
	)
	return err
}

func (db *Database) DeleteExpiredMessages() (int64, error) {
	now := time.Now().Unix()
	result, err := db.conn.Exec(
		`UPDATE messages SET is_deleted = 1, deleted_at = ?, encrypted_content = X'' 
		 WHERE expires_at IS NOT NULL AND expires_at < ? AND is_deleted = 0`,
		now, now,
	)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// ============ MESSAGE STATUS METHODS ============

func (db *Database) SetMessageStatus(messageID int64, deviceID string, status string) error {
	now := time.Now().Unix()
	_, err := db.conn.Exec(
		`INSERT INTO message_status (message_id, device_id, status, updated_at)
		 VALUES (?, ?, ?, ?)
		 ON CONFLICT(message_id, device_id) DO UPDATE SET status = ?, updated_at = ?`,
		messageID, deviceID, status, now, status, now,
	)
	return err
}

func (db *Database) GetMessageStatus(messageID int64, deviceID string) (string, error) {
	var status string
	err := db.conn.QueryRow(
		`SELECT status FROM message_status WHERE message_id = ? AND device_id = ?`,
		messageID, deviceID,
	).Scan(&status)

	if err == sql.ErrNoRows {
		return "", nil
	}
	return status, err
}

// ============ SYNC CURSOR METHODS ============

func (db *Database) GetSyncCursor(deviceID string) (int64, error) {
	var lastSeqID int64
	err := db.conn.QueryRow(
		`SELECT last_seq_id FROM sync_cursors WHERE device_id = ?`,
		deviceID,
	).Scan(&lastSeqID)

	if err == sql.ErrNoRows {
		return 0, nil
	}
	return lastSeqID, err
}

func (db *Database) UpdateSyncCursor(deviceID string, lastSeqID int64) error {
	now := time.Now().Unix()
	_, err := db.conn.Exec(
		`INSERT INTO sync_cursors (device_id, last_seq_id, updated_at)
		 VALUES (?, ?, ?)
		 ON CONFLICT(device_id) DO UPDATE SET last_seq_id = ?, updated_at = ?`,
		deviceID, lastSeqID, now, lastSeqID, now,
	)
	return err
}

// ============ FILE METHODS ============

func (db *Database) CreateFile(fileID string, uploaderID int64, fileNameEncrypted []byte, fileSize int64, mimeType, storagePath string) error {
	now := time.Now().Unix()
	expiresAt := now + int64(30*24*60*60) // 30 дней

	_, err := db.conn.Exec(
		`INSERT INTO files (id, uploader_id, file_name_encrypted, file_size, mime_type, storage_path, created_at, expires_at, is_deleted)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)`,
		fileID, uploaderID, fileNameEncrypted, fileSize, mimeType, storagePath, now, expiresAt,
	)
	return err
}

func (db *Database) GetFileByID(fileID string) (*models.File, error) {
	var f models.File
	var expiresAt sql.NullInt64
	var isDeleted int

	err := db.conn.QueryRow(
		`SELECT id, uploader_id, file_name_encrypted, file_size, mime_type, storage_path, created_at, expires_at, is_deleted
		 FROM files WHERE id = ?`,
		fileID,
	).Scan(&f.ID, &f.UploaderID, &f.FileNameEncrypted, &f.FileSize, &f.MimeType,
		&f.StoragePath, &f.CreatedAt, &expiresAt, &isDeleted)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	if expiresAt.Valid {
		f.ExpiresAt = expiresAt.Int64
	}
	f.IsDeleted = isDeleted == 1

	return &f, nil
}

func (db *Database) DeleteFile(fileID string) error {
	_, err := db.conn.Exec(
		`UPDATE files SET is_deleted = 1 WHERE id = ?`,
		fileID,
	)
	return err
}

func (db *Database) DeleteExpiredFiles() ([]string, error) {
	now := time.Now().Unix()

	rows, err := db.conn.Query(
		`SELECT storage_path FROM files 
		 WHERE expires_at IS NOT NULL AND expires_at < ? AND is_deleted = 0`,
		now,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var paths []string
	for rows.Next() {
		var path string
		rows.Scan(&path)
		paths = append(paths, path)
	}

	_, err = db.conn.Exec(
		`UPDATE files SET is_deleted = 1 
		 WHERE expires_at IS NOT NULL AND expires_at < ? AND is_deleted = 0`,
		now,
	)

	return paths, err
}

// GetUserCount возвращает количество пользователей
func (db *Database) GetUserCount() (int, error) {
	var count int
	err := db.conn.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&count)
	return count, err
}

// GetPartner возвращает "собеседника" — другого пользователя
func (db *Database) GetPartner(userID int64) (*models.User, error) {
	var user models.User
	var isAdmin int
	var publicKey []byte

	err := db.conn.QueryRow(
		`SELECT id, username, password_hash, public_key, created_at, last_seen, is_admin 
		 FROM users WHERE id != ? LIMIT 1`,
		userID,
	).Scan(&user.ID, &user.Username, &user.PasswordHash, &publicKey,
		&user.CreatedAt, &user.LastSeen, &isAdmin)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	user.PublicKey = publicKey
	user.IsAdmin = isAdmin == 1
	return &user, nil
}

// GetAllUsers возвращает всех пользователей
func (db *Database) GetAllUsers() ([]*models.User, error) {
	rows, err := db.conn.Query(
		`SELECT id, username, password_hash, public_key, created_at, last_seen, is_admin FROM users`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var users []*models.User
	for rows.Next() {
		var user models.User
		var isAdmin int
		var publicKey []byte

		err := rows.Scan(&user.ID, &user.Username, &user.PasswordHash, &publicKey,
			&user.CreatedAt, &user.LastSeen, &isAdmin)
		if err != nil {
			return nil, err
		}

		user.PublicKey = publicKey
		user.IsAdmin = isAdmin == 1
		users = append(users, &user)
	}

	return users, nil
}

func (db *Database) UpdateUserPassword(userID int64, passwordHash string) error {
	_, err := db.conn.Exec(
		`UPDATE users SET password_hash = ? WHERE id = ?`,
		passwordHash, userID,
	)
	return err
}

func (db *Database) CreateSession(userID int64, deviceID, tokenHash string, duration time.Duration) (*models.Session, error) {
	now := time.Now().Unix()
	expiresAt := now + int64(duration.Seconds())

	result, err := db.conn.Exec(
		`INSERT INTO sessions (token_hash, user_id, device_id, created_at, expires_at, is_revoked)
		 VALUES (?, ?, ?, ?, ?, 0)`,
		tokenHash, userID, deviceID, now, expiresAt,
	)
	if err != nil {
		return nil, err
	}

	id, _ := result.LastInsertId()
	return &models.Session{
		ID:        id,
		TokenHash: tokenHash,
		UserID:    userID,
		DeviceID:  deviceID,
		CreatedAt: now,
		ExpiresAt: expiresAt,
		IsRevoked: false,
	}, nil
}

func (db *Database) GetSessionByTokenHash(tokenHash string) (*models.Session, error) {
	var s models.Session
	var isRevoked int

	err := db.conn.QueryRow(
		`SELECT id, token_hash, user_id, device_id, created_at, expires_at, is_revoked
		 FROM sessions WHERE token_hash = ?`,
		tokenHash,
	).Scan(&s.ID, &s.TokenHash, &s.UserID, &s.DeviceID, &s.CreatedAt, &s.ExpiresAt, &isRevoked)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	s.IsRevoked = isRevoked == 1
	return &s, nil
}

func (db *Database) RevokeSession(tokenHash string) error {
	_, err := db.conn.Exec(
		`UPDATE sessions SET is_revoked = 1 WHERE token_hash = ?`,
		tokenHash,
	)
	return err
}

func (db *Database) RevokeAllUserSessions(userID int64) error {
	_, err := db.conn.Exec(
		`UPDATE sessions SET is_revoked = 1 WHERE user_id = ?`,
		userID,
	)
	return err
}
