package db

import (
	"crypto/rand"
	"errors"
	"io"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

func newTestDB(t *testing.T) *Database {
	t.Helper()
	key := make([]byte, 32)
	if _, err := io.ReadFull(rand.Reader, key); err != nil {
		t.Fatal(err)
	}
	database, err := New(filepath.Join(t.TempDir(), "messages.db"), key)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { database.Close() })
	return database
}

func TestUsersAreStoredWithBcrypt(t *testing.T) {
	database := newTestDB(t)

	user, err := database.CreateUser("alice", "secure_pwd_456", true)
	if err != nil {
		t.Fatal(err)
	}
	if user.PasswordHash == "secure_pwd_456" {
		t.Fatal("password must never be stored in plaintext")
	}
	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte("secure_pwd_456")); err != nil {
		t.Errorf("expected bcrypt hash: %v", err)
	}

	fetched, err := database.GetUserByUsername("alice")
	if err != nil || fetched == nil || !fetched.IsAdmin {
		t.Fatalf("expected admin user alice, got %+v err=%v", fetched, err)
	}

	if _, err := database.CreateUser("alice", "another_pwd_789", false); err == nil {
		t.Error("duplicate username must fail")
	}

	bob, _ := database.CreateUser("bob", "secure_pwd_456", false)
	partner, err := database.GetPartner(user.ID)
	if err != nil || partner == nil || partner.ID != bob.ID {
		t.Fatalf("expected bob as partner, got %+v err=%v", partner, err)
	}
	count, _ := database.GetUserCount()
	if count != 2 {
		t.Errorf("expected 2 users, got %d", count)
	}
}

func TestDevicesInsertOnly(t *testing.T) {
	database := newTestDB(t)
	alice, _ := database.CreateUser("alice", "secure_pwd_456", true)
	bob, _ := database.CreateUser("bob", "secure_pwd_456", false)

	pk := make([]byte, 32)
	dev, err := database.CreateDevice(alice.ID, "dev-1", "Phone", "android", pk)
	if err != nil {
		t.Fatal(err)
	}
	if dev.UserID != alice.ID || dev.DeviceName != "Phone" {
		t.Fatalf("unexpected device %+v", dev)
	}

	// Повторная регистрация того же device_id (даже другим пользователем) запрещена
	_, err = database.CreateDevice(bob.ID, "dev-1", "Stolen", "windows", pk)
	if !errors.Is(err, ErrDeviceExists) {
		t.Fatalf("expected ErrDeviceExists, got %v", err)
	}

	again, _ := database.GetDeviceByID("dev-1")
	if again.UserID != alice.ID || again.DeviceName != "Phone" {
		t.Fatal("existing device must not be modified by a second CreateDevice")
	}
}

func TestRevokeDeviceRevokesSessions(t *testing.T) {
	database := newTestDB(t)
	alice, _ := database.CreateUser("alice", "secure_pwd_456", true)
	if _, err := database.CreateDevice(alice.ID, "dev-1", "Phone", "android", nil); err != nil {
		t.Fatal(err)
	}
	if _, err := database.CreateDevice(alice.ID, "dev-2", "PC", "windows", nil); err != nil {
		t.Fatal(err)
	}

	if _, err := database.CreateSession(alice.ID, "dev-1", "hash1", time.Hour); err != nil {
		t.Fatal(err)
	}
	if _, err := database.CreateSession(alice.ID, "dev-2", "hash2", time.Hour); err != nil {
		t.Fatal(err)
	}

	if err := database.RevokeDevice("dev-1"); err != nil {
		t.Fatal(err)
	}

	s1, _ := database.GetSessionByTokenHash("hash1")
	if s1 == nil || !s1.IsRevoked || !s1.DeviceRevoked {
		t.Fatalf("session of revoked device must be revoked: %+v", s1)
	}
	s2, _ := database.GetSessionByTokenHash("hash2")
	if s2 == nil || s2.IsRevoked || s2.DeviceRevoked {
		t.Fatalf("session of other device must stay valid: %+v", s2)
	}

	devices, _ := database.GetUserDevices(alice.ID)
	if len(devices) != 1 || devices[0].DeviceID != "dev-2" {
		t.Errorf("GetUserDevices must list only active devices, got %+v", devices)
	}
}

func TestSessionsLifecycle(t *testing.T) {
	database := newTestDB(t)
	user, _ := database.CreateUser("test_user", "password123", false)
	if _, err := database.CreateDevice(user.ID, "device_001", "x", "y", nil); err != nil {
		t.Fatal(err)
	}

	tokenHash := "some_sha256_hash_of_token"
	session, err := database.CreateSession(user.ID, "device_001", tokenHash, 1*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if session.UserID != user.ID || session.TokenHash != tokenHash {
		t.Fatalf("unexpected session %+v", session)
	}

	s, err := database.GetSessionByTokenHash(tokenHash)
	if err != nil || s == nil || s.DeviceID != "device_001" || s.DeviceRevoked {
		t.Fatalf("expected valid session, got %+v err=%v", s, err)
	}

	// Продление
	newExp, err := database.ExtendSession(tokenHash, 48*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if newExp <= s.ExpiresAt {
		t.Errorf("expected extended expiry, got %d <= %d", newExp, s.ExpiresAt)
	}

	// Отзыв
	if err := database.RevokeSession(tokenHash); err != nil {
		t.Fatal(err)
	}
	sRevoked, _ := database.GetSessionByTokenHash(tokenHash)
	if !sRevoked.IsRevoked {
		t.Error("expected session to be revoked")
	}

	// Сессия на несуществующее устройство помечается DeviceRevoked
	if _, err := database.CreateSession(user.ID, "ghost", "hash-ghost", time.Hour); err != nil {
		t.Fatal(err)
	}
	ghost, _ := database.GetSessionByTokenHash("hash-ghost")
	if ghost == nil || !ghost.DeviceRevoked {
		t.Errorf("session for unknown device must be DeviceRevoked: %+v", ghost)
	}

	// Prune: отозванные старше 0 секунд удаляются
	pruned, err := database.PruneSessions(0)
	if err != nil {
		t.Fatal(err)
	}
	if pruned < 1 {
		t.Errorf("expected revoked session to be pruned, got %d", pruned)
	}
	if again, _ := database.GetSessionByTokenHash(tokenHash); again != nil {
		t.Error("pruned session should be gone")
	}
}

func TestMessagesTombstonesAndStatus(t *testing.T) {
	database := newTestDB(t)
	alice, _ := database.CreateUser("alice", "secure_pwd_456", true)
	bob, _ := database.CreateUser("bob", "secure_pwd_456", false)
	database.CreateDevice(bob.ID, "bob-dev", "x", "y", nil)

	m1, err := database.CreateMessage(alice.ID, bob.ID, []byte("c1"), "encrypted", "", 0)
	if err != nil {
		t.Fatal(err)
	}
	m2, _ := database.CreateMessage(alice.ID, bob.ID, []byte("c2"), "encrypted", "", 0)
	if m2.SeqID != m1.SeqID+1 {
		t.Errorf("seq ids must be sequential: %d, %d", m1.SeqID, m2.SeqID)
	}

	if err := database.DeleteMessage(m1.SeqID); err != nil {
		t.Fatal(err)
	}

	// Forward sync должен вернуть tombstone удалённого сообщения без содержимого
	msgs, err := database.GetMessagesSince(bob.ID, 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 2 {
		t.Fatalf("expected 2 messages (incl. tombstone), got %d", len(msgs))
	}
	if !msgs[0].IsDeleted || len(msgs[0].EncryptedContent) != 0 {
		t.Errorf("deleted message must be a tombstone without content: %+v", msgs[0])
	}
	if msgs[1].IsDeleted || string(msgs[1].EncryptedContent) != "c2" {
		t.Errorf("live message must keep content: %+v", msgs[1])
	}

	// Backward pagination не возвращает удалённые
	before, _ := database.GetMessagesBefore(bob.ID, m2.SeqID+1, 100)
	if len(before) != 1 || before[0].SeqID != m2.SeqID {
		t.Errorf("backward pagination must skip deleted messages, got %+v", before)
	}

	// Статусы
	if err := database.SetMessageStatus(m2.ID, "bob-dev", "delivered"); err != nil {
		t.Fatal(err)
	}
	st, _ := database.GetMessageStatus(m2.ID, "bob-dev")
	if st != "delivered" {
		t.Errorf("expected delivered, got %q", st)
	}

	// Expired cleanup
	database.conn.Exec(`UPDATE messages SET expires_at = ? WHERE seq_id = ?`, time.Now().Unix()-10, m2.SeqID)
	n, err := database.DeleteExpiredMessages()
	if err != nil || n != 1 {
		t.Errorf("expected 1 expired message deleted, got %d err=%v", n, err)
	}
}

func TestUserLastActivity(t *testing.T) {
	database := newTestDB(t)
	alice, _ := database.CreateUser("alice", "secure_pwd_456", true)
	database.CreateDevice(alice.ID, "d1", "x", "y", nil)

	base, err := database.GetUserLastActivity(alice.ID)
	if err != nil || base == 0 {
		t.Fatalf("expected activity from creation, got %d err=%v", base, err)
	}

	future := time.Now().Unix() + 3600
	if _, err := database.conn.Exec(`UPDATE devices SET last_seen = ? WHERE device_id = 'd1'`, future); err != nil {
		t.Fatal(err)
	}
	got, _ := database.GetUserLastActivity(alice.ID)
	if got != future {
		t.Errorf("expected device activity %d to be used, got %d", future, got)
	}

	// Отозванные устройства не учитываются
	database.RevokeDevice("d1")
	got, _ = database.GetUserLastActivity(alice.ID)
	if got == future {
		t.Error("revoked device activity must be ignored")
	}
}

func TestFilesAndStorageUsed(t *testing.T) {
	database := newTestDB(t)
	alice, _ := database.CreateUser("alice", "secure_pwd_456", true)

	if err := database.CreateFile("f1", alice.ID, nil, 100, "application/octet-stream", "/tmp/f1"); err != nil {
		t.Fatal(err)
	}
	if err := database.CreateFile("f2", alice.ID, nil, 250, "application/octet-stream", "/tmp/f2"); err != nil {
		t.Fatal(err)
	}

	used, err := database.GetStorageUsed()
	if err != nil || used != 350 {
		t.Fatalf("expected 350 bytes used, got %d err=%v", used, err)
	}

	if err := database.DeleteFile("f1"); err != nil {
		t.Fatal(err)
	}
	used, _ = database.GetStorageUsed()
	if used != 250 {
		t.Errorf("deleted files must not count, got %d", used)
	}

	f, _ := database.GetFileByID("f2")
	if f == nil || f.UploaderID != alice.ID || f.FileSize != 250 {
		t.Errorf("unexpected file %+v", f)
	}
}
