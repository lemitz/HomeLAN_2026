package panic

import (
	"os"
	"path/filepath"
	"testing"
)

type MockCloser struct {
	closed bool
}

func (m *MockCloser) Close() error {
	m.closed = true
	return nil
}

func TestPanicHandler(t *testing.T) {
	// Create temporary directories
	tempDir, err := os.MkdirTemp("", "homelan_panic_test")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tempDir)

	dbPath := filepath.Join(tempDir, "messages.db")
	filesDir := filepath.Join(tempDir, "files")

	if err := os.MkdirAll(filesDir, 0700); err != nil {
		t.Fatal(err)
	}

	// Create dummy DB file, WAL, SHM
	if err := os.WriteFile(dbPath, []byte("database_content_here_and_it_should_be_long_long_long_long_long_long"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dbPath+"-wal", []byte("wal_content"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dbPath+"-shm", []byte("shm_content"), 0600); err != nil {
		t.Fatal(err)
	}

	// Create dummy file attachment
	dummyFilePath := filepath.Join(filesDir, "file1")
	if err := os.WriteFile(dummyFilePath, []byte("attachment_content_here"), 0600); err != nil {
		t.Fatal(err)
	}

	mockCloser := &MockCloser{}
	completed := false

	handler := New(mockCloser, dbPath, filesDir, func() {
		completed = true
	})

	handler.Trigger("TEST_PANIC")

	// 1. Verify DB closer was closed
	if !mockCloser.closed {
		t.Error("expected DB closer to be closed")
	}

	// 2. Verify files deleted
	if _, err := os.Stat(dbPath); !os.IsNotExist(err) {
		t.Error("expected DB file to be deleted")
	}
	if _, err := os.Stat(dbPath + "-wal"); !os.IsNotExist(err) {
		t.Error("expected WAL to be deleted")
	}
	if _, err := os.Stat(dbPath + "-shm"); !os.IsNotExist(err) {
		t.Error("expected SHM to be deleted")
	}
	if _, err := os.Stat(dummyFilePath); !os.IsNotExist(err) {
		t.Error("expected dummy file attachment to be deleted")
	}

	// 3. Verify callback ran
	if !completed {
		t.Error("expected callback to run")
	}
}
