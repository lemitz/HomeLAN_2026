package linking

import (
	"strings"
	"testing"
	"time"
)

func TestLinkingService(t *testing.T) {
	ls := NewLinkingService()

	// 1. Test CreateLink and GetLink success
	link := ls.CreateLink(123)
	if link == nil {
		t.Fatal("expected link to be created")
	}
	if link.UserID != 123 {
		t.Errorf("expected userID 123, got %d", link.UserID)
	}

	code := link.Code
	if len(code) != 9 || !strings.Contains(code, "-") {
		t.Errorf("expected code in XXXX-XXXX format, got %s", code)
	}

	// 2. Test GetLink normalisation (case insensitive, dash insensitive)
	retrieved := ls.GetLink(strings.ToLower(code))
	if retrieved == nil {
		t.Fatal("expected to retrieve link with lowercase code")
	}
	if retrieved.UserID != 123 {
		t.Errorf("expected userID 123, got %d", retrieved.UserID)
	}

	// 3. Test One-Time Use (cannot retrieve again)
	secondRetrieve := ls.GetLink(code)
	if secondRetrieve != nil {
		t.Error("expected link to be deleted after first retrieve (one-time use)")
	}

	// 4. Test code without dash
	link2 := ls.CreateLink(456)
	code2 := strings.ReplaceAll(link2.Code, "-", "")
	retrieved2 := ls.GetLink(code2)
	if retrieved2 == nil {
		t.Fatal("expected to retrieve link with code without dash")
	}
	if retrieved2.UserID != 456 {
		t.Errorf("expected userID 456, got %d", retrieved2.UserID)
	}

	// 5. Test Expiration
	link3 := ls.CreateLink(789)
	link3.ExpiresAt = time.Now().Add(-1 * time.Second) // manually expire it
	expired := ls.GetLink(link3.Code)
	if expired != nil {
		t.Error("expected link to be expired and nil")
	}
}
