package linking

import (
	"strings"
	"testing"
	"time"
)

func TestCodeFormat(t *testing.T) {
	for i := 0; i < 200; i++ {
		c := generateCode()
		if len(c) != 11 || c[5] != '-' {
			t.Fatalf("bad code format: %q", c)
		}
		for _, r := range strings.ReplaceAll(c, "-", "") {
			if !strings.ContainsRune(alphabet, r) {
				t.Fatalf("unexpected char %q in %q", r, c)
			}
		}
	}
}

func TestConsumeIsBoundToDeviceAndSingleUse(t *testing.T) {
	ls := NewLinkingService()
	defer ls.Close()

	l := ls.CreateLink(1, "dev-new", "Phone", "android")

	// Чужое устройство — код сгорает.
	if ls.Consume(l.Code, "dev-attacker") != nil {
		t.Fatal("link must be bound to device id")
	}
	if ls.Consume(l.Code, "dev-new") != nil {
		t.Fatal("code must be single-use even after mismatch")
	}

	l2 := ls.CreateLink(1, "dev-new", "Phone", "android")
	lower := strings.ToLower(strings.ReplaceAll(l2.Code, "-", ""))
	got := ls.Consume(" "+lower+" ", "dev-new")
	if got == nil || got.UserID != 1 || got.DeviceName != "Phone" {
		t.Fatalf("expected successful consume with normalized code, got %+v", got)
	}
	if ls.Consume(l2.Code, "dev-new") != nil {
		t.Fatal("code reused")
	}
}

func TestNewLinkInvalidatesPrevious(t *testing.T) {
	ls := NewLinkingService()
	defer ls.Close()
	first := ls.CreateLink(7, "a", "A", "windows")
	ls.CreateLink(7, "b", "B", "windows")
	if ls.Consume(first.Code, "a") != nil {
		t.Fatal("old code should be invalidated")
	}
}

func TestExpiredLink(t *testing.T) {
	ls := NewLinkingService()
	defer ls.Close()
	l := ls.CreateLink(1, "d", "D", "android")
	ls.mu.Lock()
	l.ExpiresAt = time.Now().Add(-time.Second)
	ls.mu.Unlock()
	if ls.Consume(l.Code, "d") != nil {
		t.Fatal("expired link accepted")
	}
}
