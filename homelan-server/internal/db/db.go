// Package db — хранилище сервера HomeLAN (SQLite + SQLCipher).
//
// Модель синхронизации: у каждого сообщения есть постоянный seq_id и
// монотонный change_seq, который увеличивается при любом изменении
// (создание, доставка, прочтение, удаление). Клиент хранит курсор по
// change_seq и получает все изменения, включая удаления (tombstones).
package db

import (
	"context"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"time"

	_ "github.com/mutecomm/go-sqlcipher/v4"
	"homelan-server/internal/models"
)

// SchemaVersion — версия схемы. Старые базы (v0.x) несовместимы.
const SchemaVersion = 2

var (
	ErrUserLimit      = errors.New("user limit reached")
	ErrUsernameTaken  = errors.New("username already taken")
	ErrDeviceExists   = errors.New("device already registered")
	ErrDeviceLimit    = errors.New("device limit reached")
	ErrNotFound       = errors.New("not found")
	ErrForbidden      = errors.New("forbidden")
	ErrFileUnusable   = errors.New("file not found, not owned or already attached")
	ErrSchemaMismatch = errors.New("incompatible database schema")
)

type Database struct {
	conn *sql.DB
}

// New открывает (или создаёт) зашифрованную БД.
func New(dbPath string, encryptionKey []byte) (*Database, error) {
	if len(encryptionKey) != 32 {
		return nil, fmt.Errorf("encryption key must be 32 bytes")
	}
	if err := os.MkdirAll(filepath.Dir(dbPath), 0700); err != nil {
		return nil, fmt.Errorf("failed to create db directory: %w", err)
	}

	// Все PRAGMA передаются в DSN, чтобы применяться к каждому соединению.
	q := url.Values{}
	q.Set("_pragma_key", "x'"+hex.EncodeToString(encryptionKey)+"'")
	q.Set("_pragma_cipher_page_size", "4096")
	q.Set("_busy_timeout", "5000")
	q.Set("_foreign_keys", "1")
	q.Set("_journal_mode", "WAL")
	q.Set("_synchronous", "NORMAL")
	dsn := dbPath + "?" + q.Encode()

	conn, err := sql.Open("sqlite3", dsn)
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}
	// SQLite + маленькая нагрузка: одно соединение исключает гонки
	// и "database is locked", а транзакции становятся сериализуемыми.
	conn.SetMaxOpenConns(1)
	conn.SetConnMaxLifetime(0)

	var count int
	if err := conn.QueryRow("SELECT count(*) FROM sqlite_master").Scan(&count); err != nil {
		conn.Close()
		return nil, fmt.Errorf("database key verification failed (wrong USB key?): %w", err)
	}

	d := &Database{conn: conn}
	if err := d.initSchema(count == 0); err != nil {
		conn.Close()
		return nil, err
	}
	return d, nil
}

func (d *Database) Close() error { return d.conn.Close() }

func (d *Database) initSchema(fresh bool) error {
	var version int
	if err := d.conn.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return fmt.Errorf("read schema version: %w", err)
	}
	if !fresh && version != SchemaVersion {
		return fmt.Errorf("%w: found v%d, need v%d — delete the data directory to start fresh",
			ErrSchemaMismatch, version, SchemaVersion)
	}

	schema := `
	CREATE TABLE IF NOT EXISTS users (
		id            INTEGER PRIMARY KEY AUTOINCREMENT,
		username      TEXT UNIQUE NOT NULL COLLATE NOCASE,
		password_hash TEXT NOT NULL,
		public_key    BLOB NOT NULL,
		created_at    INTEGER NOT NULL,
		last_seen     INTEGER NOT NULL,
		is_admin      INTEGER NOT NULL DEFAULT 0
	);

	CREATE TABLE IF NOT EXISTS devices (
		id          INTEGER PRIMARY KEY AUTOINCREMENT,
		user_id     INTEGER NOT NULL REFERENCES users(id),
		device_id   TEXT UNIQUE NOT NULL,
		device_name TEXT NOT NULL,
		device_type TEXT NOT NULL,
		created_at  INTEGER NOT NULL,
		last_seen   INTEGER NOT NULL,
		is_revoked  INTEGER NOT NULL DEFAULT 0
	);

	CREATE TABLE IF NOT EXISTS sessions (
		id         INTEGER PRIMARY KEY AUTOINCREMENT,
		token_hash TEXT UNIQUE NOT NULL,
		user_id    INTEGER NOT NULL REFERENCES users(id),
		device_id  TEXT NOT NULL,
		created_at INTEGER NOT NULL,
		expires_at INTEGER NOT NULL,
		last_used  INTEGER NOT NULL,
		is_revoked INTEGER NOT NULL DEFAULT 0
	);

	CREATE TABLE IF NOT EXISTS messages (
		seq_id            INTEGER PRIMARY KEY AUTOINCREMENT,
		change_seq        INTEGER NOT NULL UNIQUE,
		sender_id         INTEGER NOT NULL REFERENCES users(id),
		sender_device     TEXT NOT NULL,
		recipient_id      INTEGER NOT NULL REFERENCES users(id),
		client_id         TEXT NOT NULL,
		encrypted_content BLOB NOT NULL,
		content_type      TEXT NOT NULL,
		file_id           TEXT,
		created_at        INTEGER NOT NULL,
		expires_at        INTEGER,
		delivered_at      INTEGER,
		read_at           INTEGER,
		is_deleted        INTEGER NOT NULL DEFAULT 0,
		deleted_at        INTEGER,
		UNIQUE(sender_id, client_id)
	);

	CREATE TABLE IF NOT EXISTS files (
		id           TEXT PRIMARY KEY,
		uploader_id  INTEGER NOT NULL REFERENCES users(id),
		file_size    INTEGER NOT NULL,
		storage_path TEXT NOT NULL,
		created_at   INTEGER NOT NULL,
		expires_at   INTEGER,
		attached     INTEGER NOT NULL DEFAULT 0,
		is_deleted   INTEGER NOT NULL DEFAULT 0
	);

	CREATE TABLE IF NOT EXISTS counters (
		name  TEXT PRIMARY KEY,
		value INTEGER NOT NULL
	);

	CREATE INDEX IF NOT EXISTS idx_messages_sender    ON messages(sender_id);
	CREATE INDEX IF NOT EXISTS idx_messages_recipient ON messages(recipient_id);
	CREATE INDEX IF NOT EXISTS idx_messages_file      ON messages(file_id);
	CREATE INDEX IF NOT EXISTS idx_devices_user       ON devices(user_id);
	CREATE INDEX IF NOT EXISTS idx_sessions_device    ON sessions(device_id);
	`
	if _, err := d.conn.Exec(schema); err != nil {
		return fmt.Errorf("create schema: %w", err)
	}
	if _, err := d.conn.Exec(fmt.Sprintf("PRAGMA user_version = %d", SchemaVersion)); err != nil {
		return fmt.Errorf("set schema version: %w", err)
	}
	return nil
}

func now() int64 { return time.Now().Unix() }

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func (d *Database) withTx(fn func(tx *sql.Tx) error) error {
	tx, err := d.conn.BeginTx(context.Background(), nil)
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		tx.Rollback()
		return err
	}
	return tx.Commit()
}

// nextChangeSeq выдаёт следующий номер изменения внутри транзакции.
// (Встроенный SQLite 3.33 не поддерживает RETURNING.)
func nextChangeSeq(tx *sql.Tx) (int64, error) {
	if _, err := tx.Exec(`
		INSERT INTO counters(name, value) VALUES('change_seq', 1)
		ON CONFLICT(name) DO UPDATE SET value = value + 1`); err != nil {
		return 0, err
	}
	var v int64
	err := tx.QueryRow(`SELECT value FROM counters WHERE name = 'change_seq'`).Scan(&v)
	return v, err
}

// ============ USERS ============

const userCols = `id, username, password_hash, public_key, created_at, last_seen, is_admin`

func scanUser(row interface{ Scan(...any) error }) (*models.User, error) {
	var u models.User
	var isAdmin int
	err := row.Scan(&u.ID, &u.Username, &u.PasswordHash, &u.PublicKey, &u.CreatedAt, &u.LastSeen, &isAdmin)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	u.IsAdmin = isAdmin == 1
	return &u, nil
}

// RegisterParams — данные для регистрации пользователя вместе с первым устройством.
type RegisterParams struct {
	Username     string
	PasswordHash string
	PublicKey    []byte
	DeviceID     string
	DeviceName   string
	DeviceType   string
	MaxUsers     int
}

// RegisterUser атомарно создаёт пользователя и его первое устройство.
// Первый зарегистрированный пользователь становится администратором.
func (d *Database) RegisterUser(p RegisterParams) (*models.User, *models.Device, error) {
	var user *models.User
	var device *models.Device
	err := d.withTx(func(tx *sql.Tx) error {
		var count int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&count); err != nil {
			return err
		}
		if count >= p.MaxUsers {
			return ErrUserLimit
		}
		var exists int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM users WHERE username = ?`, p.Username).Scan(&exists); err != nil {
			return err
		}
		if exists > 0 {
			return ErrUsernameTaken
		}
		if err := tx.QueryRow(`SELECT COUNT(*) FROM devices WHERE device_id = ?`, p.DeviceID).Scan(&exists); err != nil {
			return err
		}
		if exists > 0 {
			return ErrDeviceExists
		}

		ts := now()
		isAdmin := count == 0
		res, err := tx.Exec(`INSERT INTO users (username, password_hash, public_key, created_at, last_seen, is_admin)
			VALUES (?, ?, ?, ?, ?, ?)`, p.Username, p.PasswordHash, p.PublicKey, ts, ts, boolInt(isAdmin))
		if err != nil {
			return err
		}
		id, _ := res.LastInsertId()
		user = &models.User{ID: id, Username: p.Username, PasswordHash: p.PasswordHash,
			PublicKey: p.PublicKey, CreatedAt: ts, LastSeen: ts, IsAdmin: isAdmin}

		device, err = insertDevice(tx, id, p.DeviceID, p.DeviceName, p.DeviceType, ts)
		return err
	})
	if err != nil {
		return nil, nil, err
	}
	return user, device, nil
}

func (d *Database) GetUserByUsername(username string) (*models.User, error) {
	return scanUser(d.conn.QueryRow(`SELECT `+userCols+` FROM users WHERE username = ?`, username))
}

func (d *Database) GetUserByID(id int64) (*models.User, error) {
	return scanUser(d.conn.QueryRow(`SELECT `+userCols+` FROM users WHERE id = ?`, id))
}

// GetPartner возвращает собеседника — первого пользователя, отличного от userID.
func (d *Database) GetPartner(userID int64) (*models.User, error) {
	return scanUser(d.conn.QueryRow(`SELECT `+userCols+` FROM users WHERE id != ? ORDER BY id LIMIT 1`, userID))
}

func (d *Database) GetAdmin() (*models.User, error) {
	return scanUser(d.conn.QueryRow(`SELECT ` + userCols + ` FROM users WHERE is_admin = 1 ORDER BY id LIMIT 1`))
}

func (d *Database) GetUserCount() (int, error) {
	var c int
	err := d.conn.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&c)
	return c, err
}

// TouchUser отмечает активность пользователя (нужно для Dead Man's Switch).
func (d *Database) TouchUser(userID int64) error {
	_, err := d.conn.Exec(`UPDATE users SET last_seen = ? WHERE id = ?`, now(), userID)
	return err
}

// ============ DEVICES ============

const deviceCols = `id, user_id, device_id, device_name, device_type, created_at, last_seen, is_revoked`

func scanDevice(row interface{ Scan(...any) error }) (*models.Device, error) {
	var dv models.Device
	var revoked int
	err := row.Scan(&dv.ID, &dv.UserID, &dv.DeviceID, &dv.DeviceName, &dv.DeviceType, &dv.CreatedAt, &dv.LastSeen, &revoked)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	dv.IsRevoked = revoked == 1
	return &dv, nil
}

func insertDevice(tx *sql.Tx, userID int64, deviceID, name, typ string, ts int64) (*models.Device, error) {
	res, err := tx.Exec(`INSERT INTO devices (user_id, device_id, device_name, device_type, created_at, last_seen, is_revoked)
		VALUES (?, ?, ?, ?, ?, ?, 0)`, userID, deviceID, name, typ, ts, ts)
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	return &models.Device{ID: id, UserID: userID, DeviceID: deviceID, DeviceName: name,
		DeviceType: typ, CreatedAt: ts, LastSeen: ts}, nil
}

// CreateDevice строго добавляет новое устройство пользователю (без перезаписи
// существующих) с проверкой лимита активных устройств.
func (d *Database) CreateDevice(userID int64, deviceID, name, typ string, maxDevices int) (*models.Device, error) {
	var device *models.Device
	err := d.withTx(func(tx *sql.Tx) error {
		var exists int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM devices WHERE device_id = ?`, deviceID).Scan(&exists); err != nil {
			return err
		}
		if exists > 0 {
			return ErrDeviceExists
		}
		var active int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM devices WHERE user_id = ? AND is_revoked = 0`, userID).Scan(&active); err != nil {
			return err
		}
		if active >= maxDevices {
			return ErrDeviceLimit
		}
		var err error
		device, err = insertDevice(tx, userID, deviceID, name, typ, now())
		return err
	})
	return device, err
}

func (d *Database) CountActiveDevices(userID int64) (int, error) {
	var c int
	err := d.conn.QueryRow(`SELECT COUNT(*) FROM devices WHERE user_id = ? AND is_revoked = 0`, userID).Scan(&c)
	return c, err
}

func (d *Database) GetDevice(deviceID string) (*models.Device, error) {
	return scanDevice(d.conn.QueryRow(`SELECT `+deviceCols+` FROM devices WHERE device_id = ?`, deviceID))
}

func (d *Database) DeviceExists(deviceID string) (bool, error) {
	var c int
	err := d.conn.QueryRow(`SELECT COUNT(*) FROM devices WHERE device_id = ?`, deviceID).Scan(&c)
	return c > 0, err
}

// ListUserDevices возвращает активные (не отозванные) устройства пользователя.
func (d *Database) ListUserDevices(userID int64) ([]*models.Device, error) {
	rows, err := d.conn.Query(`SELECT `+deviceCols+` FROM devices WHERE user_id = ? AND is_revoked = 0 ORDER BY id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*models.Device
	for rows.Next() {
		dv, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, dv)
	}
	return out, rows.Err()
}

func (d *Database) TouchDevice(deviceID string) error {
	_, err := d.conn.Exec(`UPDATE devices SET last_seen = ? WHERE device_id = ?`, now(), deviceID)
	return err
}

// LastActivity — время последней активности пользователя по любому устройству.
func (d *Database) LastActivity(userID int64) (int64, error) {
	var ts sql.NullInt64
	err := d.conn.QueryRow(`
		SELECT MAX(t) FROM (
			SELECT last_seen AS t FROM users WHERE id = ?
			UNION ALL
			SELECT MAX(last_seen) FROM devices WHERE user_id = ? AND is_revoked = 0
		)`, userID, userID).Scan(&ts)
	return ts.Int64, err
}

// RevokeDevice отзывает устройство и все его сессии.
func (d *Database) RevokeDevice(deviceID string) error {
	return d.withTx(func(tx *sql.Tx) error {
		if _, err := tx.Exec(`UPDATE devices SET is_revoked = 1 WHERE device_id = ?`, deviceID); err != nil {
			return err
		}
		_, err := tx.Exec(`UPDATE sessions SET is_revoked = 1 WHERE device_id = ?`, deviceID)
		return err
	})
}

// ============ SESSIONS ============

func (d *Database) CreateSession(userID int64, deviceID, tokenHash string, ttl time.Duration) (*models.Session, error) {
	ts := now()
	exp := ts + int64(ttl.Seconds())
	res, err := d.conn.Exec(`INSERT INTO sessions (token_hash, user_id, device_id, created_at, expires_at, last_used, is_revoked)
		VALUES (?, ?, ?, ?, ?, ?, 0)`, tokenHash, userID, deviceID, ts, exp, ts)
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	return &models.Session{ID: id, TokenHash: tokenHash, UserID: userID, DeviceID: deviceID,
		CreatedAt: ts, ExpiresAt: exp, LastUsed: ts}, nil
}

func (d *Database) GetSessionByTokenHash(tokenHash string) (*models.Session, error) {
	var s models.Session
	var revoked int
	err := d.conn.QueryRow(`SELECT id, token_hash, user_id, device_id, created_at, expires_at, last_used, is_revoked
		FROM sessions WHERE token_hash = ?`, tokenHash).
		Scan(&s.ID, &s.TokenHash, &s.UserID, &s.DeviceID, &s.CreatedAt, &s.ExpiresAt, &s.LastUsed, &revoked)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	s.IsRevoked = revoked == 1
	return &s, nil
}

// ExtendSession продлевает сессию (скользящий срок жизни).
func (d *Database) ExtendSession(id int64, ttl time.Duration) error {
	ts := now()
	_, err := d.conn.Exec(`UPDATE sessions SET last_used = ?, expires_at = ? WHERE id = ?`, ts, ts+int64(ttl.Seconds()), id)
	return err
}

func (d *Database) RevokeSession(tokenHash string) error {
	_, err := d.conn.Exec(`UPDATE sessions SET is_revoked = 1 WHERE token_hash = ?`, tokenHash)
	return err
}

// DeleteStaleSessions удаляет истёкшие и отозванные сессии.
func (d *Database) DeleteStaleSessions() (int64, error) {
	res, err := d.conn.Exec(`DELETE FROM sessions WHERE is_revoked = 1 OR expires_at < ?`, now())
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// ============ MESSAGES ============

const msgCols = `seq_id, change_seq, sender_id, sender_device, recipient_id, client_id, encrypted_content,
	content_type, file_id, created_at, expires_at, delivered_at, read_at, is_deleted, deleted_at`

func scanMessage(row interface{ Scan(...any) error }) (*models.Message, error) {
	var m models.Message
	var fileID sql.NullString
	var expires, delivered, read, deletedAt sql.NullInt64
	var deleted int
	err := row.Scan(&m.SeqID, &m.ChangeSeq, &m.SenderID, &m.SenderDevice, &m.RecipientID, &m.ClientID,
		&m.EncryptedContent, &m.ContentType, &fileID, &m.CreatedAt, &expires, &delivered, &read, &deleted, &deletedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	m.FileID = fileID.String
	m.ExpiresAt = expires.Int64
	m.DeliveredAt = delivered.Int64
	m.ReadAt = read.Int64
	m.IsDeleted = deleted == 1
	m.DeletedAt = deletedAt.Int64
	if m.EncryptedContent == nil {
		m.EncryptedContent = []byte{}
	}
	return &m, nil
}

func queryMessages(q interface {
	Query(string, ...any) (*sql.Rows, error)
}, query string, args ...any) ([]*models.Message, error) {
	rows, err := q.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []*models.Message{}
	for rows.Next() {
		m, err := scanMessage(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func getMessageTx(tx *sql.Tx, seqID int64) (*models.Message, error) {
	return scanMessage(tx.QueryRow(`SELECT `+msgCols+` FROM messages WHERE seq_id = ?`, seqID))
}

func nullable(v int64) any {
	if v == 0 {
		return nil
	}
	return v
}

// NewMessage — входные данные для создания сообщения.
type NewMessage struct {
	SenderID         int64
	SenderDevice     string
	RecipientID      int64
	ClientID         string
	EncryptedContent []byte
	ContentType      string
	FileID           string
	ExpiresAt        int64
}

// InsertMessage создаёт сообщение. Повторная отправка с тем же client_id
// идемпотентна: возвращается уже сохранённое сообщение и duplicate=true.
func (d *Database) InsertMessage(n NewMessage) (msg *models.Message, duplicate bool, err error) {
	err = d.withTx(func(tx *sql.Tx) error {
		existing, err := scanMessage(tx.QueryRow(`SELECT `+msgCols+` FROM messages WHERE sender_id = ? AND client_id = ?`,
			n.SenderID, n.ClientID))
		if err != nil {
			return err
		}
		if existing != nil {
			msg, duplicate = existing, true
			return nil
		}

		if n.FileID != "" {
			res, err := tx.Exec(`UPDATE files SET attached = 1
				WHERE id = ? AND uploader_id = ? AND attached = 0 AND is_deleted = 0`, n.FileID, n.SenderID)
			if err != nil {
				return err
			}
			if c, _ := res.RowsAffected(); c != 1 {
				return ErrFileUnusable
			}
		}

		cs, err := nextChangeSeq(tx)
		if err != nil {
			return err
		}
		var fileID any
		if n.FileID != "" {
			fileID = n.FileID
		}
		res, err := tx.Exec(`INSERT INTO messages (change_seq, sender_id, sender_device, recipient_id, client_id,
			encrypted_content, content_type, file_id, created_at, expires_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			cs, n.SenderID, n.SenderDevice, n.RecipientID, n.ClientID, n.EncryptedContent, n.ContentType,
			fileID, now(), nullable(n.ExpiresAt))
		if err != nil {
			return err
		}
		id, _ := res.LastInsertId()
		msg, err = getMessageTx(tx, id)
		return err
	})
	return msg, duplicate, err
}

func (d *Database) GetMessage(seqID int64) (*models.Message, error) {
	return scanMessage(d.conn.QueryRow(`SELECT `+msgCols+` FROM messages WHERE seq_id = ?`, seqID))
}

// ChangesSince возвращает все изменения переписки пользователя после курсора
// (включая tombstones удалённых сообщений), по возрастанию change_seq.
func (d *Database) ChangesSince(userID, sinceChange int64, limit int) ([]*models.Message, error) {
	return queryMessages(d.conn, `SELECT `+msgCols+` FROM messages
		WHERE (sender_id = ? OR recipient_id = ?) AND change_seq > ?
		ORDER BY change_seq ASC LIMIT ?`, userID, userID, sinceChange, limit)
}

// HistoryBefore — постраничная загрузка истории назад (без удалённых).
func (d *Database) HistoryBefore(userID, beforeSeq int64, limit int) ([]*models.Message, error) {
	return queryMessages(d.conn, `SELECT `+msgCols+` FROM messages
		WHERE (sender_id = ? OR recipient_id = ?) AND seq_id < ? AND is_deleted = 0
		ORDER BY seq_id DESC LIMIT ?`, userID, userID, beforeSeq, limit)
}

// MaxChangeSeq — текущее значение курсора изменений.
func (d *Database) MaxChangeSeq() (int64, error) {
	var v sql.NullInt64
	err := d.conn.QueryRow(`SELECT value FROM counters WHERE name = 'change_seq'`).Scan(&v)
	if err == sql.ErrNoRows {
		return 0, nil
	}
	return v.Int64, err
}

// MarkDelivered помечает сообщение доставленным получателю.
// Возвращает обновлённое сообщение или nil, если менять нечего.
func (d *Database) MarkDelivered(seqID, recipientID int64) (*models.Message, error) {
	var out *models.Message
	err := d.withTx(func(tx *sql.Tx) error {
		m, err := getMessageTx(tx, seqID)
		if err != nil || m == nil {
			return err
		}
		if m.RecipientID != recipientID || m.IsDeleted || m.DeliveredAt != 0 {
			return nil
		}
		cs, err := nextChangeSeq(tx)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(`UPDATE messages SET delivered_at = ?, change_seq = ? WHERE seq_id = ?`, now(), cs, seqID); err != nil {
			return err
		}
		out, err = getMessageTx(tx, seqID)
		return err
	})
	return out, err
}

// MarkReadUpTo помечает прочитанными все входящие сообщения пользователя
// recipientID с seq_id <= upToSeq. Возвращает изменённые сообщения.
func (d *Database) MarkReadUpTo(recipientID, upToSeq int64) ([]*models.Message, error) {
	var out []*models.Message
	err := d.withTx(func(tx *sql.Tx) error {
		rows, err := tx.Query(`SELECT seq_id FROM messages
			WHERE recipient_id = ? AND seq_id <= ? AND read_at IS NULL AND is_deleted = 0
			ORDER BY seq_id`, recipientID, upToSeq)
		if err != nil {
			return err
		}
		var ids []int64
		for rows.Next() {
			var id int64
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return err
			}
			ids = append(ids, id)
		}
		rows.Close()

		ts := now()
		for _, id := range ids {
			cs, err := nextChangeSeq(tx)
			if err != nil {
				return err
			}
			if _, err := tx.Exec(`UPDATE messages SET read_at = ?, delivered_at = COALESCE(delivered_at, ?), change_seq = ?
				WHERE seq_id = ?`, ts, ts, cs, id); err != nil {
				return err
			}
			m, err := getMessageTx(tx, id)
			if err != nil {
				return err
			}
			out = append(out, m)
		}
		return nil
	})
	return out, err
}

func tombstoneTx(tx *sql.Tx, seqID int64) (*models.Message, error) {
	cs, err := nextChangeSeq(tx)
	if err != nil {
		return nil, err
	}
	if _, err := tx.Exec(`UPDATE messages SET is_deleted = 1, deleted_at = ?, encrypted_content = X'', change_seq = ?
		WHERE seq_id = ?`, now(), cs, seqID); err != nil {
		return nil, err
	}
	return getMessageTx(tx, seqID)
}

// DeleteMessage удаляет сообщение (для всех). Удалять может только отправитель.
// Возвращает tombstone и ID прикреплённого файла (его нужно удалить с диска).
func (d *Database) DeleteMessage(seqID, requesterID int64) (*models.Message, string, error) {
	var out *models.Message
	var fileID string
	err := d.withTx(func(tx *sql.Tx) error {
		m, err := getMessageTx(tx, seqID)
		if err != nil {
			return err
		}
		if m == nil {
			return ErrNotFound
		}
		if m.SenderID != requesterID {
			return ErrForbidden
		}
		if m.IsDeleted {
			out = m
			return nil
		}
		fileID = m.FileID
		out, err = tombstoneTx(tx, seqID)
		return err
	})
	return out, fileID, err
}

// DeleteExpiredMessages превращает просроченные сообщения в tombstones.
func (d *Database) DeleteExpiredMessages() ([]*models.Message, []string, error) {
	var out []*models.Message
	var files []string
	err := d.withTx(func(tx *sql.Tx) error {
		rows, err := tx.Query(`SELECT seq_id, COALESCE(file_id, '') FROM messages
			WHERE expires_at IS NOT NULL AND expires_at < ? AND is_deleted = 0`, now())
		if err != nil {
			return err
		}
		type item struct {
			id   int64
			file string
		}
		var items []item
		for rows.Next() {
			var it item
			if err := rows.Scan(&it.id, &it.file); err != nil {
				rows.Close()
				return err
			}
			items = append(items, it)
		}
		rows.Close()
		for _, it := range items {
			m, err := tombstoneTx(tx, it.id)
			if err != nil {
				return err
			}
			out = append(out, m)
			if it.file != "" {
				files = append(files, it.file)
			}
		}
		return nil
	})
	return out, files, err
}

// ============ FILES ============

const fileCols = `id, uploader_id, file_size, storage_path, created_at, expires_at, attached, is_deleted`

func scanFile(row interface{ Scan(...any) error }) (*models.File, error) {
	var f models.File
	var expires sql.NullInt64
	var attached, deleted int
	err := row.Scan(&f.ID, &f.UploaderID, &f.FileSize, &f.StoragePath, &f.CreatedAt, &expires, &attached, &deleted)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	f.ExpiresAt = expires.Int64
	f.Attached = attached == 1
	f.IsDeleted = deleted == 1
	return &f, nil
}

func (d *Database) CreateFile(fileID string, uploaderID, size int64, storagePath string, retention time.Duration) error {
	ts := now()
	var expires any
	if retention > 0 {
		expires = ts + int64(retention.Seconds())
	}
	_, err := d.conn.Exec(`INSERT INTO files (id, uploader_id, file_size, storage_path, created_at, expires_at)
		VALUES (?, ?, ?, ?, ?, ?)`, fileID, uploaderID, size, storagePath, ts, expires)
	return err
}

func (d *Database) GetFile(fileID string) (*models.File, error) {
	return scanFile(d.conn.QueryRow(`SELECT `+fileCols+` FROM files WHERE id = ?`, fileID))
}

// CanAccessFile: файл доступен загрузившему и получателю сообщения с этим файлом.
func (d *Database) CanAccessFile(f *models.File, userID int64) (bool, error) {
	if f.UploaderID == userID {
		return true, nil
	}
	var c int
	err := d.conn.QueryRow(`SELECT COUNT(*) FROM messages WHERE file_id = ? AND recipient_id = ? AND is_deleted = 0`,
		f.ID, userID).Scan(&c)
	return c > 0, err
}

// MarkFileDeleted помечает файл удалённым и возвращает путь к нему на диске.
func (d *Database) MarkFileDeleted(fileID string) (string, error) {
	var path string
	err := d.withTx(func(tx *sql.Tx) error {
		err := tx.QueryRow(`SELECT storage_path FROM files WHERE id = ? AND is_deleted = 0`, fileID).Scan(&path)
		if err == sql.ErrNoRows {
			return nil
		}
		if err != nil {
			return err
		}
		_, err = tx.Exec(`UPDATE files SET is_deleted = 1 WHERE id = ?`, fileID)
		return err
	})
	return path, err
}

// CollectGarbageFiles помечает удалёнными просроченные файлы и файлы,
// которые так и не прикрепили к сообщению (orphanAge). Возвращает пути.
func (d *Database) CollectGarbageFiles(orphanAge time.Duration) ([]string, error) {
	ts := now()
	var paths []string
	err := d.withTx(func(tx *sql.Tx) error {
		rows, err := tx.Query(`SELECT id, storage_path FROM files
			WHERE is_deleted = 0 AND (
				(expires_at IS NOT NULL AND expires_at < ?) OR
				(attached = 0 AND created_at < ?)
			)`, ts, ts-int64(orphanAge.Seconds()))
		if err != nil {
			return err
		}
		var ids []string
		for rows.Next() {
			var id, p string
			if err := rows.Scan(&id, &p); err != nil {
				rows.Close()
				return err
			}
			ids = append(ids, id)
			paths = append(paths, p)
		}
		rows.Close()
		for _, id := range ids {
			if _, err := tx.Exec(`UPDATE files SET is_deleted = 1 WHERE id = ?`, id); err != nil {
				return err
			}
		}
		return nil
	})
	return paths, err
}

// TotalFileBytes — суммарный размер неудалённых файлов (для квоты).
func (d *Database) TotalFileBytes() (int64, error) {
	var v sql.NullInt64
	err := d.conn.QueryRow(`SELECT SUM(file_size) FROM files WHERE is_deleted = 0`).Scan(&v)
	return v.Int64, err
}
