package server

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"homelan-server/internal/config"
	"homelan-server/internal/db"
	"homelan-server/internal/panic"
)

type fakePanic struct {
	mu      sync.Mutex
	reasons []panic.Reason
}

func (f *fakePanic) Trigger(r panic.Reason) {
	f.mu.Lock()
	f.reasons = append(f.reasons, r)
	f.mu.Unlock()
}

func (f *fakePanic) got() []panic.Reason {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]panic.Reason(nil), f.reasons...)
}

type env struct {
	t     *testing.T
	srv   *Server
	http  *httptest.Server
	panic *fakePanic
	db    *db.Database
}

func newEnv(t *testing.T, mutate ...func(*config.Config)) *env {
	t.Helper()
	dir := t.TempDir()
	cfg := config.Default()
	cfg.Database.Path = filepath.Join(dir, "db", "messages.db")
	cfg.Files.StoragePath = filepath.Join(dir, "files")
	cfg.Files.MaxFileMB = 1
	for _, m := range mutate {
		m(cfg)
	}
	database, err := db.New(cfg.Database.Path, bytes.Repeat([]byte{7}, 32))
	if err != nil {
		t.Fatal(err)
	}
	fp := &fakePanic{}
	s := New(cfg, database, fp)
	hs := httptest.NewServer(s.Handler())
	t.Cleanup(func() {
		hs.Close()
		s.links.Close()
		database.Close()
	})
	return &env{t: t, srv: s, http: hs, panic: fp, db: database}
}

func (e *env) call(method, path, token string, body any) (int, map[string]any) {
	e.t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, e.http.URL+path, rd)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

var pubKey = bytes.Repeat([]byte{9}, 32)

func devID(name string) string { return fmt.Sprintf("%-20s", name+"-device")[:20] }

func cleanID(s string) string { return strings.ReplaceAll(s, " ", "x") }

func (e *env) register(name string) (token string, userID int64, device string) {
	e.t.Helper()
	device = cleanID(devID(name))
	code, out := e.call("POST", "/api/register", "", map[string]any{
		"username": name, "password": "password-" + name, "device_id": device,
		"device_name": name + " phone", "device_type": "android", "public_key": pubKey,
	})
	if code != 200 {
		e.t.Fatalf("register %s: %d %v", name, code, out)
	}
	user := out["user"].(map[string]any)
	return out["token"].(string), int64(user["id"].(float64)), device
}

func TestRegisterLoginAndDeviceRules(t *testing.T) {
	e := newEnv(t)
	aliceTok, _, aliceDev := e.register("alice")

	// Слабый пароль и неверный ключ отклоняются.
	code, out := e.call("POST", "/api/register", "", map[string]any{
		"username": "bob", "password": "123", "device_id": cleanID(devID("bob")), "device_type": "android", "public_key": pubKey})
	if code != 400 || out["error"] != "weak_password" {
		t.Fatalf("expected weak_password, got %d %v", code, out)
	}
	code, out = e.call("POST", "/api/register", "", map[string]any{
		"username": "bob", "password": "password-bob", "device_id": cleanID(devID("bob")), "device_type": "android", "public_key": []byte{1, 2}})
	if code != 400 || out["error"] != "invalid_public_key" {
		t.Fatalf("expected invalid_public_key, got %d %v", code, out)
	}

	// Вход с привязанного устройства работает.
	code, out = e.call("POST", "/api/login", "", map[string]any{"username": "alice", "password": "password-alice", "device_id": aliceDev})
	if code != 200 || out["token"] == nil {
		t.Fatalf("login failed: %d %v", code, out)
	}
	// С нового устройства — нет (только linking).
	code, out = e.call("POST", "/api/login", "", map[string]any{"username": "alice", "password": "password-alice", "device_id": cleanID(devID("unknown"))})
	if code != 403 || out["error"] != "device_not_linked" {
		t.Fatalf("expected device_not_linked, got %d %v", code, out)
	}

	// Сессия валидна, у alice пока нет партнёра.
	code, out = e.call("GET", "/api/session", aliceTok, nil)
	if code != 200 || out["partner"] != nil {
		t.Fatalf("session: %d %v", code, out)
	}

	_, bobID, _ := e.register("bob")
	code, out = e.call("GET", "/api/partner", aliceTok, nil)
	if code != 200 || int64(out["partner"].(map[string]any)["id"].(float64)) != bobID {
		t.Fatalf("partner: %d %v", code, out)
	}

	// Третьего пользователя быть не может.
	code, out = e.call("POST", "/api/register", "", map[string]any{
		"username": "carol", "password": "password-carol", "device_id": cleanID(devID("carol")), "device_type": "android", "public_key": pubKey})
	if code != 403 || out["error"] != "user_limit" {
		t.Fatalf("expected user_limit, got %d %v", code, out)
	}

	// Logout отзывает токен.
	e.call("POST", "/api/logout", aliceTok, nil)
	if code, _ := e.call("GET", "/api/session", aliceTok, nil); code != 401 {
		t.Fatalf("token must be revoked after logout, got %d", code)
	}
}

func TestLoginRateLimit(t *testing.T) {
	e := newEnv(t)
	e.register("alice")
	for i := 0; i < 5; i++ {
		e.call("POST", "/api/login", "", map[string]any{"username": "alice", "password": "wrong-password", "device_id": "x"})
	}
	code, out := e.call("POST", "/api/login", "", map[string]any{"username": "alice", "password": "password-alice", "device_id": "x"})
	if code != 429 || out["error"] != "rate_limited" {
		t.Fatalf("expected rate limit, got %d %v", code, out)
	}
}

func TestDuressPassword(t *testing.T) {
	e := newEnv(t, func(c *config.Config) { c.Security.DuressPassword = "duress-secret" })
	_, _, dev := e.register("alice")
	code, out := e.call("POST", "/api/login", "", map[string]any{"username": "anyone", "password": "duress-secret", "device_id": dev})
	if code != 401 || out["error"] != "invalid_credentials" {
		t.Fatalf("duress must look like a normal failure, got %d %v", code, out)
	}
	deadline := time.Now().Add(2 * time.Second)
	for len(e.panic.got()) == 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if got := e.panic.got(); len(got) != 1 || got[0] != panic.ReasonDuress {
		t.Fatalf("expected duress wipe, got %v", got)
	}
}

func TestLinkingAndRevocation(t *testing.T) {
	e := newEnv(t)
	aliceTok, _, _ := e.register("alice")
	newDev := cleanID(devID("alicepc"))

	code, out := e.call("POST", "/api/devices/link/create", aliceTok, map[string]any{
		"device_id": newDev, "device_name": "PC", "device_type": "windows"})
	if code != 200 {
		t.Fatalf("link create: %d %v", code, out)
	}
	linkCode := out["link_code"].(string)

	// Код привязан к устройству: чужой device_id не проходит и сжигает код.
	code, _ = e.call("POST", "/api/devices/link/complete", "", map[string]any{"link_code": linkCode, "device_id": cleanID(devID("evil"))})
	if code != 400 {
		t.Fatalf("expected rejection for wrong device, got %d", code)
	}
	code, _ = e.call("POST", "/api/devices/link/complete", "", map[string]any{"link_code": linkCode, "device_id": newDev})
	if code != 400 {
		t.Fatalf("burned code must not work, got %d", code)
	}

	_, out = e.call("POST", "/api/devices/link/create", aliceTok, map[string]any{
		"device_id": newDev, "device_name": "PC", "device_type": "windows"})
	code, out = e.call("POST", "/api/devices/link/complete", "", map[string]any{"link_code": out["link_code"], "device_id": newDev})
	if code != 200 {
		t.Fatalf("link complete: %d %v", code, out)
	}
	pcTok := out["token"].(string)
	if !bytes.Equal(decodeB64(t, out["user"].(map[string]any)["public_key"]), pubKey) {
		t.Fatal("linked device must receive the user's identity public key")
	}

	code, out = e.call("GET", "/api/devices", aliceTok, nil)
	if code != 200 || len(out["devices"].([]any)) != 2 {
		t.Fatalf("devices: %d %v", code, out)
	}

	// Отзыв: токен устройства перестаёт работать на ВСЕХ эндпоинтах.
	code, _ = e.call("POST", "/api/devices/revoke", aliceTok, map[string]any{"device_id": newDev})
	if code != 200 {
		t.Fatalf("revoke: %d", code)
	}
	for _, path := range []string{"/api/session", "/api/devices", "/api/partner"} {
		if code, _ := e.call("GET", path, pcTok, nil); code != 401 {
			t.Fatalf("revoked device still has access to %s: %d", path, code)
		}
	}
	if code, _ := e.call("POST", "/api/devices/link/create", pcTok, map[string]any{
		"device_id": cleanID(devID("x2")), "device_type": "windows"}); code != 401 {
		t.Fatalf("revoked device must not create link codes, got %d", code)
	}
}

func TestDeviceLimit(t *testing.T) {
	e := newEnv(t, func(c *config.Config) { c.Security.MaxDevicesPerUser = 1 })
	tok, _, _ := e.register("alice")
	code, out := e.call("POST", "/api/devices/link/create", tok, map[string]any{
		"device_id": cleanID(devID("second")), "device_type": "windows"})
	if code != 403 || out["error"] != "device_limit" {
		t.Fatalf("expected device_limit, got %d %v", code, out)
	}
}

func TestPanicRequiresAdminAndPassword(t *testing.T) {
	e := newEnv(t)
	adminTok, _, _ := e.register("alice")
	bobTok, _, _ := e.register("bob")

	if code, _ := e.call("POST", "/api/panic", bobTok, map[string]any{"password": "password-bob", "confirm": "DESTROY_ALL_DATA"}); code != 403 {
		t.Fatalf("non-admin panic must be forbidden, got %d", code)
	}
	if code, _ := e.call("POST", "/api/panic", adminTok, map[string]any{"password": "nope", "confirm": "DESTROY_ALL_DATA"}); code != 401 {
		t.Fatalf("wrong password must be rejected, got %d", code)
	}
	code, _ := e.call("POST", "/api/panic", adminTok, map[string]any{"password": "password-alice", "confirm": "DESTROY_ALL_DATA"})
	if code != 200 {
		t.Fatalf("panic: %d", code)
	}
	time.Sleep(700 * time.Millisecond)
	if got := e.panic.got(); len(got) != 1 || got[0] != panic.ReasonManual {
		t.Fatalf("expected manual wipe, got %v", got)
	}
}

func TestDeadManSwitch(t *testing.T) {
	e := newEnv(t)
	_, aliceID, _ := e.register("alice")
	e.srv.checkDeadMan(time.Now())
	if len(e.panic.got()) != 0 {
		t.Fatal("must not trigger for active admin")
	}
	e.srv.checkDeadMan(time.Unix(0, 0))
	if len(e.panic.got()) != 0 {
		t.Fatal("must not trigger with invalid clock")
	}
	e.srv.checkDeadMan(time.Now().Add(31 * 24 * time.Hour))
	if got := e.panic.got(); len(got) != 1 || got[0] != panic.ReasonDeadMan {
		t.Fatalf("expected dead man wipe for user %d, got %v", aliceID, got)
	}
}

func decodeB64(t *testing.T, v any) []byte {
	t.Helper()
	var b []byte
	raw, _ := json.Marshal(v)
	if err := json.Unmarshal(raw, &b); err != nil {
		t.Fatal(err)
	}
	return b
}

func (e *env) upload(token string, data []byte) (int, map[string]any) {
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	fw, _ := mw.CreateFormFile("file", "blob")
	fw.Write(data)
	mw.Close()
	req, _ := http.NewRequest("POST", e.http.URL+"/api/files/upload", &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func (e *env) dial(token string) *websocket.Conn {
	e.t.Helper()
	url := "ws" + strings.TrimPrefix(e.http.URL, "http") + "/ws"
	conn, resp, err := websocket.DefaultDialer.Dial(url, http.Header{"Authorization": {"Bearer " + token}})
	if err != nil {
		e.t.Fatalf("dial: %v (%v)", err, resp)
	}
	e.t.Cleanup(func() { conn.Close() })
	return conn
}

// readMessageWith ждёт событие "message", в котором есть поле field.
func readMessageWith(t *testing.T, c *websocket.Conn, field string) map[string]any {
	t.Helper()
	for {
		m := readUntil(t, c, "message")
		if m[field] != nil {
			return m
		}
	}
}

func readUntil(t *testing.T, c *websocket.Conn, typ string) map[string]any {
	t.Helper()
	c.SetReadDeadline(time.Now().Add(3 * time.Second))
	for {
		var env struct {
			Type string         `json:"type"`
			Data map[string]any `json:"data"`
		}
		if err := c.ReadJSON(&env); err != nil {
			t.Fatalf("waiting for %s: %v", typ, err)
		}
		if env.Type == typ {
			return env.Data
		}
	}
}

func TestWebSocketMessagingAndFiles(t *testing.T) {
	e := newEnv(t)
	aliceTok, _, _ := e.register("alice")
	bobTok, bobID, _ := e.register("bob")

	// Без токена и с Origin браузера — отказ.
	url := "ws" + strings.TrimPrefix(e.http.URL, "http") + "/ws"
	if _, resp, err := websocket.DefaultDialer.Dial(url, nil); err == nil || resp.StatusCode != 401 {
		t.Fatal("ws without token must be rejected")
	}
	if _, _, err := websocket.DefaultDialer.Dial(url, http.Header{
		"Authorization": {"Bearer " + aliceTok}, "Origin": {"http://evil.example"}}); err == nil {
		t.Fatal("browser origin must be rejected")
	}

	alice := e.dial(aliceTok)
	bob := e.dial(bobTok)

	// Незашифрованное содержимое не принимается.
	alice.WriteJSON(map[string]any{"type": "send_message", "data": map[string]any{
		"client_id": "p1", "recipient_id": bobID, "content_type": "text", "encrypted_content": []byte("plain")}})
	if f := readUntil(t, alice, "send_failed"); f["code"] != "unsupported_crypto" {
		t.Fatalf("expected unsupported_crypto, got %v", f)
	}

	// Файл: загрузка, прикрепление, скачивание с Range.
	payload := append([]byte{2}, bytes.Repeat([]byte("abc"), 100)...)
	code, up := e.upload(aliceTok, payload)
	if code != 200 {
		t.Fatalf("upload: %d %v", code, up)
	}
	fileID := up["file_id"].(string)
	if code, _ := e.upload(aliceTok, bytes.Repeat([]byte{1}, 2<<20)); code != 413 {
		t.Fatalf("oversized upload must be rejected, got %d", code)
	}

	alice.WriteJSON(map[string]any{"type": "send_message", "data": map[string]any{
		"client_id": "c1", "recipient_id": bobID, "content_type": "file", "file_id": fileID,
		"encrypted_content": []byte{2, 9, 9, 9}}})
	sent := readUntil(t, alice, "message_sent")
	seq := int64(sent["seq_id"].(float64))
	got := readUntil(t, bob, "message")
	if int64(got["seq_id"].(float64)) != seq || got["file_id"] != fileID {
		t.Fatalf("bob got wrong message: %v", got)
	}

	req, _ := http.NewRequest("GET", e.http.URL+"/api/files/"+fileID, nil)
	req.Header.Set("Authorization", "Bearer "+bobTok)
	req.Header.Set("Range", "bytes=-3")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	tail, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 206 || string(tail) != "abc" {
		t.Fatalf("suffix range broken: %d %q", resp.StatusCode, tail)
	}

	// Ack и read доходят до отправителя как обновления сообщения.
	bob.WriteJSON(map[string]any{"type": "ack", "data": map[string]any{"seq_id": seq}})
	readMessageWith(t, alice, "delivered_at")
	bob.WriteJSON(map[string]any{"type": "read", "data": map[string]any{"up_to_seq": seq}})
	readMessageWith(t, alice, "read_at")

	// Повторная отправка того же client_id не создаёт дубль.
	alice.WriteJSON(map[string]any{"type": "send_message", "data": map[string]any{
		"client_id": "c1", "recipient_id": bobID, "content_type": "file", "file_id": fileID,
		"encrypted_content": []byte{2, 9, 9, 9}}})
	if again := readUntil(t, alice, "message_sent"); int64(again["seq_id"].(float64)) != seq {
		t.Fatal("resend must return the same seq_id")
	}

	// Удаление: tombstone приходит в синке, файл больше не скачивается.
	alice.WriteJSON(map[string]any{"type": "delete", "data": map[string]any{"seq_id": seq}})
	readUntil(t, bob, "message")
	bob.WriteJSON(map[string]any{"type": "sync", "data": map[string]any{"since": 0}})
	syncResp := readUntil(t, bob, "sync_response")
	msgs := syncResp["messages"].([]any)
	if len(msgs) != 1 || msgs[0].(map[string]any)["is_deleted"] != true {
		t.Fatalf("sync must return tombstone, got %v", msgs)
	}
	req, _ = http.NewRequest("GET", e.http.URL+"/api/files/"+fileID, nil)
	req.Header.Set("Authorization", "Bearer "+aliceTok)
	resp, _ = http.DefaultClient.Do(req)
	resp.Body.Close()
	if resp.StatusCode != 410 {
		t.Fatalf("deleted file must be gone, got %d", resp.StatusCode)
	}
}
