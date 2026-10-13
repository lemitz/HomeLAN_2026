package usb

import (
	"os"
	"path/filepath"
	"testing"
)

func TestGenerateKeyFileDoesNotOverwrite(t *testing.T) {
	dir := t.TempDir()

	mk, err := GenerateKeyFile(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(mk.Key) != KeySize {
		t.Fatalf("expected %d byte key, got %d", KeySize, len(mk.Key))
	}

	data, err := os.ReadFile(filepath.Join(dir, KeyFileName))
	if err != nil {
		t.Fatal(err)
	}
	if len(data) != KeySize*2+1 {
		t.Fatalf("unexpected key file length %d", len(data))
	}

	if _, err := GenerateKeyFile(dir); err == nil {
		t.Fatal("expected error when key already exists")
	}

	again, err := os.ReadFile(filepath.Join(dir, KeyFileName))
	if err != nil {
		t.Fatal(err)
	}
	if string(again) != string(data) {
		t.Fatal("existing key must not be modified")
	}
}

func TestIsWritableDir(t *testing.T) {
	if !IsWritableDir(t.TempDir()) {
		t.Error("temp dir should be writable")
	}
	if IsWritableDir(filepath.Join(t.TempDir(), "missing")) {
		t.Error("missing dir should not be writable")
	}
}
