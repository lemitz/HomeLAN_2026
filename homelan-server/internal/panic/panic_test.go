package panic

import (
	"os"
	"path/filepath"
	"testing"
)

type mockCloser struct{ closed int }

func (m *mockCloser) Close() error { m.closed++; return nil }

func setup(t *testing.T) (dir, dbPath, filesDir, keyPath, attachment string) {
	t.Helper()
	dir = t.TempDir()
	dbPath = filepath.Join(dir, "messages.db")
	filesDir = filepath.Join(dir, "files")
	keyPath = filepath.Join(dir, "usb", "homelan.key")
	attachment = filepath.Join(filesDir, "file1")
	for _, d := range []string{filesDir, filepath.Dir(keyPath)} {
		if err := os.MkdirAll(d, 0700); err != nil {
			t.Fatal(err)
		}
	}
	for path, content := range map[string]string{
		dbPath:          "database_content",
		dbPath + "-wal": "wal",
		dbPath + "-shm": "shm",
		attachment:      "attachment",
		keyPath:         "00112233",
	} {
		if err := os.WriteFile(path, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return
}

func gone(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("expected %s to be deleted", path)
	}
}

func TestPanicWipesEverythingIncludingKey(t *testing.T) {
	_, dbPath, filesDir, keyPath, attachment := setup(t)
	closer := &mockCloser{}
	completed := 0
	h := New(closer, dbPath, filesDir, keyPath, func() { completed++ })

	h.Trigger(ReasonDuress)
	h.Trigger(ReasonDeadMan) // повтор игнорируется

	if closer.closed != 1 || completed != 1 {
		t.Fatalf("expected single run, closed=%d completed=%d", closer.closed, completed)
	}
	for _, p := range []string{dbPath, dbPath + "-wal", dbPath + "-shm", attachment, keyPath} {
		gone(t, p)
	}
}

func TestPanicOnUSBRemovalDoesNotTouchKeyPath(t *testing.T) {
	_, dbPath, filesDir, keyPath, _ := setup(t)
	h := New(&mockCloser{}, dbPath, filesDir, keyPath, nil)
	h.Trigger(ReasonUSBRemoved)

	gone(t, dbPath)
	if _, err := os.Stat(keyPath); err != nil {
		t.Errorf("key file should be left alone on USB removal: %v", err)
	}
}
