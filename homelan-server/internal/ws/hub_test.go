package ws

import (
	"sync"
	"testing"
)

func newTestClient(h *Hub, userID int64, deviceID string) *Client {
	c := &Client{
		hub:      h,
		send:     make(chan []byte, 4),
		done:     make(chan struct{}),
		userID:   userID,
		deviceID: deviceID,
	}
	h.mu.Lock()
	if old := h.clients[deviceID]; old != nil {
		old.close()
	}
	h.clients[deviceID] = c
	h.mu.Unlock()
	return c
}

// Конкурентная отправка, вытеснение и отключение не должны паниковать.
func TestHubConcurrentSendAndDisconnect(t *testing.T) {
	h := NewHub(nil)
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(3)
		go func() { defer wg.Done(); newTestClient(h, 1, "dev") }()
		go func() { defer wg.Done(); h.SendToUser(1, []byte("x"), "") }()
		go func() { defer wg.Done(); h.DisconnectDevice("dev") }()
	}
	wg.Wait()
}

func TestSlowClientIsDropped(t *testing.T) {
	h := NewHub(nil)
	c := newTestClient(h, 1, "dev")
	for i := 0; i < 10; i++ {
		h.SendToUser(1, []byte("x"), "")
	}
	select {
	case <-c.done:
	default:
		t.Fatal("slow client must be closed when its buffer overflows")
	}
}

func TestExcludeDevice(t *testing.T) {
	h := NewHub(nil)
	a := newTestClient(h, 1, "a")
	b := newTestClient(h, 1, "b")
	other := newTestClient(h, 2, "c")
	h.SendToUser(1, []byte("x"), "a")
	if len(a.send) != 0 || len(b.send) != 1 || len(other.send) != 0 {
		t.Fatalf("unexpected delivery a=%d b=%d other=%d", len(a.send), len(b.send), len(other.send))
	}
}
