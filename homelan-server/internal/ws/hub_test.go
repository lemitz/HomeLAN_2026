package ws

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// newTestConn создаёт настоящее websocket-соединение (клиентскую сторону),
// чтобы conn.Close() в хабе не падал на пустом *websocket.Conn.
func newTestConn(t *testing.T) *websocket.Conn {
	t.Helper()
	upgrader := websocket.Upgrader{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		// Держим серверную сторону открытой до закрытия клиентом
		for {
			if _, _, err := c.ReadMessage(); err != nil {
				return
			}
		}
	}))
	t.Cleanup(srv.Close)

	url := "ws" + strings.TrimPrefix(srv.URL, "http")
	conn, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

func TestHubConcurrencyAndDuplicateConnections(t *testing.T) {
	hub := NewHub(nil)
	go hub.Run()

	const numDevices = 5
	const concurrency = 10

	var wg sync.WaitGroup
	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for d := 0; d < numDevices; d++ {
				// Повторная регистрация того же device_id должна вытеснять старое соединение
				client := newClient(hub, &websocket.Conn{}, 1, "device_id")
				hub.register <- client
				time.Sleep(5 * time.Millisecond)
			}
		}(i)
	}

	wg.Wait()
	time.Sleep(50 * time.Millisecond)

	hub.mu.RLock()
	client, ok := hub.clients["device_id"]
	hub.mu.RUnlock()

	if !ok || client == nil {
		t.Error("expected to find active client for device_id")
	}
}

// Регрессионный тест: раньше hub закрывал канал send, в который параллельно писал
// ReadPump (sendJSON), что приводило к panic "send on closed channel" и падению
// всего сервера. Теперь send никогда не закрывается, а закрытие сигнализируется
// через done.
func TestClientSendAfterCloseDoesNotPanic(t *testing.T) {
	hub := NewHub(nil)
	go hub.Run()

	old := newClient(hub, newTestConn(t), 1, "dev-race")
	hub.register <- old

	var wg sync.WaitGroup
	stop := make(chan struct{})

	// Писатель, имитирующий ReadPump -> sendJSON
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
				old.sendJSON(map[string]interface{}{"type": "pong"})
			}
		}
	}()

	// Параллельно вытесняем клиента повторным подключением и явным отключением
	for i := 0; i < 20; i++ {
		replacement := newClient(hub, newTestConn(t), 1, "dev-race")
		hub.register <- replacement
		hub.DisconnectDevice("dev-race")
		hub.unregister <- old
	}

	close(stop)
	wg.Wait()

	if old.trySend([]byte("x")) {
		t.Error("expected trySend to fail for closed client")
	}

	// Повторное закрытие должно быть безопасным
	old.close()
	old.close()
}

func TestTrySendBufferFull(t *testing.T) {
	hub := NewHub(nil)
	client := newClient(hub, &websocket.Conn{}, 1, "dev-full")

	for i := 0; i < cap(client.send); i++ {
		if !client.trySend([]byte("m")) {
			t.Fatalf("unexpected failure at %d", i)
		}
	}
	if client.trySend([]byte("overflow")) {
		t.Error("expected trySend to return false when buffer is full")
	}
}

func TestBroadcastTargetsOnlyRecipientDevices(t *testing.T) {
	hub := NewHub(nil)

	a1 := newClient(hub, &websocket.Conn{}, 1, "a1")
	a2 := newClient(hub, &websocket.Conn{}, 1, "a2")
	b1 := newClient(hub, &websocket.Conn{}, 2, "b1")

	hub.mu.Lock()
	hub.clients["a1"] = a1
	hub.clients["a2"] = a2
	hub.clients["b1"] = b1
	hub.mu.Unlock()

	hub.handleBroadcast(&BroadcastMessage{RecipientID: 1, Data: []byte("hi"), ExcludeDevice: "a1"})

	if len(a1.send) != 0 {
		t.Error("excluded device must not receive message")
	}
	if len(a2.send) != 1 {
		t.Error("other device of recipient must receive message")
	}
	if len(b1.send) != 0 {
		t.Error("other user must not receive message")
	}

	if !hub.IsDeviceOnline("b1") {
		t.Error("expected b1 online")
	}
	if got := hub.GetOnlineDevices(1); len(got) != 2 {
		t.Errorf("expected 2 devices for user 1, got %d", len(got))
	}
}
