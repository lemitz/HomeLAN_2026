-- HomeLAN Messenger — схема серверной БД (SQLCipher).
-- Справочная копия: авторитетная схема находится в internal/db/db.go (initSchema)
-- и применяется автоматически при старте сервера. Этот файл НЕ нужно выполнять вручную.

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
CREATE INDEX IF NOT EXISTS idx_sessions_device ON sessions(device_id);
CREATE INDEX IF NOT EXISTS idx_files_uploader ON files(uploader_id);
CREATE INDEX IF NOT EXISTS idx_message_status_message ON message_status(message_id);
