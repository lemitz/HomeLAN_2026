package panic

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

type MockCloser struct {
	closed int
}

func (m *MockCloser) Close() error {
	m.closed++
	return nil
}

func TestPanicHandler(t *testing.T) {
	tempDir := t.TempDir()

	dbPath := filepath.Join(tempDir, "messages.db")
	filesDir := filepath.Join(tempDir, "files")

	if err := os.MkdirAll(filesDir, 0700); err != nil {
		t.Fatal(err)
	}

	if err := os.WriteFile(dbPath, bytes.Repeat([]byte("database_content_"), 1000), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dbPath+"-wal", []byte("wal_content"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dbPath+"-shm", []byte("shm_content"), 0600); err != nil {
		t.Fatal(err)
	}

	dummyFilePath := filepath.Join(filesDir, "file1")
	if err := os.WriteFile(dummyFilePath, []byte("attachment_content_here"), 0600); err != nil {
		t.Fatal(err)
	}

	mockCloser := &MockCloser{}
	completed := 0

	handler := New(mockCloser, dbPath, filesDir, func() {
		completed++
	})

	handler.Trigger("TEST_PANIC")
	// Повторный вызов должен быть проигнорирован (sync.Once)
	handler.Trigger("TEST_PANIC_AGAIN")

	if mockCloser.closed != 1 {
		t.Errorf("expected DB closer to be closed exactly once, got %d", mockCloser.closed)
	}

	for _, p := range []string{dbPath, dbPath + "-wal", dbPath + "-shm", dummyFilePath} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("expected %s to be deleted", p)
		}
	}

	if completed != 1 {
		t.Errorf("expected callback to run exactly once, got %d", completed)
	}
}

func TestOverwriteFileFull(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "db")

	original := bytes.Repeat([]byte("SECRET-PAGE-"), 3*overwriteChunk/12) // > 1 chunk
	if err := os.WriteFile(path, original, 0600); err != nil {
		t.Fatal(err)
	}

	if err := overwriteFile(path, 0); err != nil {
		t.Fatal(err)
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != len(original) {
		t.Fatalf("size changed: %d -> %d", len(original), len(after))
	}
	if bytes.Contains(after, []byte("SECRET-PAGE-")) {
		t.Error("original content still present after full overwrite")
	}
}

func TestOverwriteFileLimit(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "att")

	original := bytes.Repeat([]byte("A"), 10000)
	if err := os.WriteFile(path, original, 0600); err != nil {
		t.Fatal(err)
	}

	if err := overwriteFile(path, 4096); err != nil {
		t.Fatal(err)
	}

	after, _ := os.ReadFile(path)
	if bytes.Equal(after[:4096], original[:4096]) {
		t.Error("header not overwritten")
	}
	if !bytes.Equal(after[4096:], original[4096:]) {
		t.Error("tail must stay intact when limit is set")
	}
}

func TestMissingFilesDoNotPanic(t *testing.T) {
	dir := t.TempDir()
	handler := New(nil, filepath.Join(dir, "nope.db"), filepath.Join(dir, "nofiles"), nil)
	handler.Trigger("MISSING")
}
