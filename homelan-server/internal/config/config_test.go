package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeCfg(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(p, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestDefaults(t *testing.T) {
	cfg, err := Load(writeCfg(t, "server:\n  host: 0.0.0.0\n"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Server.Port != DefaultPort || cfg.Files.StoragePath != DefaultStoragePath ||
		cfg.Files.MaxFileSizeMB != DefaultMaxFileSizeMB || cfg.Files.MaxSizeMB != DefaultMaxStorageMB ||
		cfg.Security.MaxUsers != DefaultMaxUsers || cfg.DeadMan.TimeoutDays != DefaultDeadManDays {
		t.Errorf("defaults not applied: %+v", cfg)
	}
	if cfg.MaxFileSizeBytes() != 100<<20 {
		t.Errorf("unexpected max file size %d", cfg.MaxFileSizeBytes())
	}
}

func TestRejectsExampleDuressPassword(t *testing.T) {
	_, err := Load(writeCfg(t, "security:\n  duress_password: \"panic123\"\n"))
	if err == nil || !strings.Contains(err.Error(), "well-known") {
		t.Fatalf("expected well-known duress password to be rejected, got %v", err)
	}
}

func TestRejectsShortDuressPassword(t *testing.T) {
	_, err := Load(writeCfg(t, "security:\n  duress_password: \"abc\"\n"))
	if err == nil || !strings.Contains(err.Error(), "too short") {
		t.Fatalf("expected short duress password to be rejected, got %v", err)
	}
}

func TestAcceptsGoodDuressPassword(t *testing.T) {
	cfg, err := Load(writeCfg(t, "security:\n  duress_password: \"correct-horse-battery\"\n"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Security.DuressPassword != "correct-horse-battery" {
		t.Error("duress password not loaded")
	}
}

func TestRejectsQuotaSmallerThanFile(t *testing.T) {
	_, err := Load(writeCfg(t, "files:\n  max_size_mb: 10\n  max_file_size_mb: 100\n"))
	if err == nil {
		t.Fatal("expected error when quota < max file size")
	}
}
