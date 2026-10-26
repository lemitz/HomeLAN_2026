package db

import (
	"bytes"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

var testKey = bytes.Repeat([]byte{0x42}, 32)

func openTest(t *testing.T) (*Database, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.db")
	d, err := New(path, testKey)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	return d, path
}

func register(t *testing.T, d *Database, name, device string) int64 {
	t.Helper()
	u, dev, err := d.RegisterUser(RegisterParams{
		Username: name, PasswordHash: "h", PublicKey: bytes.Repeat([]byte{1}, 32),
		DeviceID: device, DeviceName: "dev", DeviceType: "android", MaxUsers: 2,
	})
	if err != nil {
		t.Fatalf("register %s: %v", name, err)
	}
	if dev.UserID != u.ID {
		t.Fatal("device not bound to user")
	}
	return u.ID
}

func TestWrongKeyAndSchemaVersion(t *testing.T) {
	d, path := openTest(t)
	register(t, d, "alice", "dev-alice-000000000")
	d.Close()

	if _, err := New(path, bytes.Repeat([]byte{0x13}, 32)); err == nil {
		t.Fatal("expected error with wrong key")
	}
	d2, err := New(path, testKey)
	if err != nil {
		t.Fatalf("reopen with right key: %v", err)
	}
	d2.Close()
}

func TestRegisterRules(t *testing.T) {
	d, _ := openTest(t)
	alice := register(t, d, "alice", "dev-alice-000000000")

	admin, _ := d.GetAdmin()
	if admin == nil || admin.ID != alice {
		t.Fatal("first user must be admin")
	}

	p := RegisterParams{Username: "ALICE", PasswordHash: "h", PublicKey: make([]byte, 32),
		DeviceID: "dev-other-000000000", DeviceName: "x", DeviceType: "android", MaxUsers: 2}
	if _, _, err := d.RegisterUser(p); !errors.Is(err, ErrUsernameTaken) {
		t.Fatalf("usernames must be case-insensitive unique, got %v", err)
	}

	p.Username, p.DeviceID = "bob", "dev-alice-000000000"
	if _, _, err := d.RegisterUser(p); !errors.Is(err, ErrDeviceExists) {
		t.Fatalf("must not steal existing device, got %v", err)
	}
	if n, _ := d.GetUserCount(); n != 1 {
		t.Fatalf("failed registration must not leave orphan user, users=%d", n)
	}

	register(t, d, "bob", "dev-bob-00000000000")
	p.Username, p.DeviceID = "carol", "dev-carol-000000000"
	if _, _, err := d.RegisterUser(p); !errors.Is(err, ErrUserLimit) {
		t.Fatalf("expected user limit, got %v", err)
	}
	bobUser, _ := d.GetUserByUsername("bob")
	if bobUser.IsAdmin {
		t.Fatal("second user must not be admin")
	}
}

func TestDevicesAndSessions(t *testing.T) {
	d, _ := openTest(t)
	alice := register(t, d, "alice", "dev-alice-000000000")

	if _, err := d.CreateDevice(alice, "dev-alice-000000000", "x", "windows", 3); !errors.Is(err, ErrDeviceExists) {
		t.Fatalf("expected ErrDeviceExists, got %v", err)
	}
	if _, err := d.CreateDevice(alice, "dev-alice-pc0000000", "PC", "windows", 2); err != nil {
		t.Fatal(err)
	}
	if _, err := d.CreateDevice(alice, "dev-alice-pc2000000", "PC2", "windows", 2); !errors.Is(err, ErrDeviceLimit) {
		t.Fatalf("expected device limit, got %v", err)
	}

	if _, err := d.CreateSession(alice, "dev-alice-pc0000000", "hash1", time.Hour); err != nil {
		t.Fatal(err)
	}
	if err := d.RevokeDevice("dev-alice-pc0000000"); err != nil {
		t.Fatal(err)
	}
	s, _ := d.GetSessionByTokenHash("hash1")
	if s == nil || !s.IsRevoked {
		t.Fatal("revoking a device must revoke its sessions")
	}
	if n, _ := d.CountActiveDevices(alice); n != 1 {
		t.Fatalf("expected 1 active device, got %d", n)
	}
	// После отзыва место освобождается.
	if _, err := d.CreateDevice(alice, "dev-alice-pc2000000", "PC2", "windows", 2); err != nil {
		t.Fatalf("slot should be free after revoke: %v", err)
	}
}

func msg(sender, recipient int64, clientID string) NewMessage {
	return NewMessage{SenderID: sender, SenderDevice: "d", RecipientID: recipient, ClientID: clientID,
		EncryptedContent: []byte{2, 1, 2, 3}, ContentType: "text"}
}

func TestMessagesSyncTombstonesAndStatus(t *testing.T) {
	d, _ := openTest(t)
	alice := register(t, d, "alice", "dev-alice-000000000")
	bob := register(t, d, "bob", "dev-bob-00000000000")

	m1, dup, err := d.InsertMessage(msg(alice, bob, "c1"))
	if err != nil || dup {
		t.Fatalf("insert: %v dup=%v", err, dup)
	}
	again, dup, err := d.InsertMessage(msg(alice, bob, "c1"))
	if err != nil || !dup || again.SeqID != m1.SeqID {
		t.Fatalf("resend must be idempotent: %v dup=%v", err, dup)
	}
	m2, _, _ := d.InsertMessage(msg(bob, alice, "c1")) // тот же client_id у другого отправителя — ок

	changes, _ := d.ChangesSince(bob, 0, 100)
	if len(changes) != 2 {
		t.Fatalf("expected 2 changes, got %d", len(changes))
	}
	cursor := changes[len(changes)-1].ChangeSeq

	// Доставка: только получатель может отметить.
	if m, _ := d.MarkDelivered(m1.SeqID, alice); m != nil {
		t.Fatal("sender must not mark own message delivered")
	}
	if m, _ := d.MarkDelivered(m1.SeqID, bob); m == nil || m.DeliveredAt == 0 {
		t.Fatal("recipient should mark delivered")
	}
	if m, _ := d.MarkDelivered(m1.SeqID, bob); m != nil {
		t.Fatal("second delivery mark must be a no-op")
	}

	read, _ := d.MarkReadUpTo(alice, m2.SeqID)
	if len(read) != 1 || read[0].SeqID != m2.SeqID || read[0].ReadAt == 0 {
		t.Fatalf("expected m2 read, got %+v", read)
	}

	// Удаление: только отправитель; tombstone приходит в синке.
	if _, _, err := d.DeleteMessage(m1.SeqID, bob); !errors.Is(err, ErrForbidden) {
		t.Fatalf("expected forbidden, got %v", err)
	}
	tomb, _, err := d.DeleteMessage(m1.SeqID, alice)
	if err != nil || !tomb.IsDeleted || len(tomb.EncryptedContent) != 0 {
		t.Fatalf("bad tombstone: %+v %v", tomb, err)
	}

	changes, _ = d.ChangesSince(bob, cursor, 100)
	foundTomb := false
	for _, c := range changes {
		if c.ChangeSeq <= cursor {
			t.Fatal("changes must be after cursor")
		}
		if c.SeqID == m1.SeqID && c.IsDeleted {
			foundTomb = true
		}
	}
	if !foundTomb {
		t.Fatal("tombstone must be delivered by sync after cursor")
	}

	hist, _ := d.HistoryBefore(alice, m2.SeqID+1, 10)
	if len(hist) != 1 || hist[0].SeqID != m2.SeqID {
		t.Fatalf("history must skip deleted messages, got %d", len(hist))
	}
}

func TestExpiredMessages(t *testing.T) {
	d, _ := openTest(t)
	alice := register(t, d, "alice", "dev-alice-000000000")
	bob := register(t, d, "bob", "dev-bob-00000000000")
	n := msg(alice, bob, "x")
	n.ExpiresAt = time.Now().Add(-time.Minute).Unix()
	if _, _, err := d.InsertMessage(n); err != nil {
		t.Fatal(err)
	}
	expired, _, err := d.DeleteExpiredMessages()
	if err != nil || len(expired) != 1 || !expired[0].IsDeleted {
		t.Fatalf("expected one expired tombstone, got %v %v", expired, err)
	}
}

func TestFileAttachmentAndAccess(t *testing.T) {
	d, _ := openTest(t)
	alice := register(t, d, "alice", "dev-alice-000000000")
	bob := register(t, d, "bob", "dev-bob-00000000000")

	if err := d.CreateFile("f1", alice, 10, "/tmp/f1", 0); err != nil {
		t.Fatal(err)
	}
	f, _ := d.GetFile("f1")
	if ok, _ := d.CanAccessFile(f, bob); ok {
		t.Fatal("bob must not access unattached file")
	}

	m := msg(alice, bob, "file")
	m.ContentType, m.FileID = "image", "f1"
	bobFile := m
	bobFile.SenderID, bobFile.RecipientID, bobFile.ClientID = bob, alice, "steal"
	if _, _, err := d.InsertMessage(bobFile); !errors.Is(err, ErrFileUnusable) {
		t.Fatalf("must not attach someone else's file, got %v", err)
	}
	sent, _, err := d.InsertMessage(m)
	if err != nil {
		t.Fatal(err)
	}
	if ok, _ := d.CanAccessFile(f, bob); !ok {
		t.Fatal("recipient must access attached file")
	}
	m.ClientID = "again"
	if _, _, err := d.InsertMessage(m); !errors.Is(err, ErrFileUnusable) {
		t.Fatalf("file must be attachable only once, got %v", err)
	}

	_, fileID, _ := d.DeleteMessage(sent.SeqID, alice)
	if fileID != "f1" {
		t.Fatalf("delete must return attached file id, got %q", fileID)
	}
	if ok, _ := d.CanAccessFile(f, bob); ok {
		t.Fatal("access must end after message deletion")
	}
	path, _ := d.MarkFileDeleted("f1")
	if path != "/tmp/f1" {
		t.Fatalf("unexpected path %q", path)
	}
}

func TestOrphanFilesCollected(t *testing.T) {
	d, _ := openTest(t)
	alice := register(t, d, "alice", "dev-alice-000000000")
	d.CreateFile("orphan", alice, 1, "/tmp/orphan", 0)
	d.conn.Exec(`UPDATE files SET created_at = created_at - 100000 WHERE id = 'orphan'`)
	paths, err := d.CollectGarbageFiles(24 * time.Hour)
	if err != nil || len(paths) != 1 || paths[0] != "/tmp/orphan" {
		t.Fatalf("expected orphan collected, got %v %v", paths, err)
	}
}
