package ws

import (
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestHubConcurrencyAndDuplicateConnections(t *testing.T) {
	// Create hub
	hub := NewHub(nil)
	go hub.Run()

	const numDevices = 5
	const concurrency = 10

	var wg sync.WaitGroup
	// Concurrently register clients
	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for d := 0; d < numDevices; d++ {
				// Register client with same device ID to test duplicate connection eviction
				deviceID := "device_id"
				client := &Client{
					hub:      hub,
					conn:     &websocket.Conn{}, // dummy conn
					send:     make(chan []byte, 256),
					userID:   1,
					deviceID: deviceID,
				}
				hub.register <- client
				time.Sleep(5 * time.Millisecond)
			}
		}(i)
	}

	wg.Wait()
	time.Sleep(50 * time.Millisecond)

	// Verify that hub remains responsive, maps don't panic, and clients are managed correctly
	hub.mu.RLock()
	client, ok := hub.clients["device_id"]
	hub.mu.RUnlock()

	if !ok || client == nil {
		t.Error("expected to find active client for device_id")
	}
}
