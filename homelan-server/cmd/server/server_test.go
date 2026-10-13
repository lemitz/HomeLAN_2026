package main

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"homelan-server/internal/config"
)

// ============ Тестовая обвязка ============

type testEnv struct {
	t         *testing.T
	srv       *Server
	http      *httptest.Server
	dataDir   string
	exitCalls int32
}

func newTestEnv(t *testing.T, mutate func(*config.Config)) *testEnv {
	t.Helper()
	dir := t.TempDir()

	cfg := &config.Config{}
	cfg.ApplyDefaults()
	cfg.Server.Host = "127.0.0.1"
	cfg.Database.Path = filepath.Join(dir, "messages.db")
	cfg.Files.StoragePath = filepath.Join(dir, "files")
	cfg.Files.MaxFileSizeMB = 1
	cfg.Files.MaxSizeMB = 2
	cfg.Security.DuressPassword = "correct-horse-battery-staple"
	if mutate != nil {
		mutate(cfg)
	}
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}

	key := make([]byte, 32)
	if _, err := io.ReadFull(rand.Reader, key); err != nil {
		t.Fatal(err)
	}

	srv, err := NewServer(cfg, key, "")
	if err != nil {
		t.Fatal(err)
	}
	env := &testEnv{t: t, srv: srv, dataDir: dir}
	srv.exitFunc = func() { atomic.AddInt32(&env.exitCalls, 1) }

	go srv.hub.Run()
	env.http = httptest.NewServer(srv.routes())
	t.Cleanup(func() {
		env.http.Close()
		srv.db.Close()
	})
	return env
}

func (e *testEnv) do(method, path, token string, body interface{}) (*http.Response, []byte) {
	e.t.Helper()
	var rdr io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rdr = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, e.http.URL+path, rdr)
	if err != nil {
		e.t.Fatal(err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp, data
}

func (e *testEnv) doJSON(method, path, token string, body interface{}, wantStatus int) map[string]interface{} {
	e.t.Helper()
	resp, data := e.do(method, path, token, body)
	if resp.StatusCode != wantStatus {
		e.t.Fatalf("%s %s: expected %d, got %d: %s", method, path, wantStatus, resp.StatusCode, data)
	}
	var out map[string]interface{}
	if len(data) > 0 && resp.Header.Get("Content-Type") == "application/json" {
		if err := json.Unmarshal(data, &out); err != nil {
			e.t.Fatalf("invalid json: %v: %s", err, data)
		}
	}
	return out
}

func pubkey(b byte) []byte {
	k := make([]byte, 32)
	for i := range k {
		k[i] = b
	}
	return k
}

func (e *testEnv) register(username, password, deviceID string, key []byte) (string, int64) {
	e.t.Helper()
	out := e.doJSON("POST", "/api/register", "", map[string]interface{}{
		"username":    username,
		"password":    password,
		"device_id":   deviceID,
		"device_name": "Test device",
		"device_type": "test",
		"public_key":  key,
	}, http.StatusOK)
	return out["token"].(string), int64(out["user_id"].(float64))
}

func (e *testEnv) login(username, password, deviceID string) (*http.Response, map[string]interface{}) {
	e.t.Helper()
	resp, data := e.do("POST", "/api/login", "", map[string]interface{}{
		"username":  username,
		"password":  password,
		"device_id": deviceID,
	})
	var out map[string]interface{}
	json.Unmarshal(data, &out)
	return resp, out
}

func (e *testEnv) wsDial(token, deviceID string) (*websocket.Conn, *http.Response, error) {
	url := "ws" + strings.TrimPrefix(e.http.URL, "http") + "/ws"
	if deviceID != "" {
		url += "?device_id=" + deviceID
	}
	h := http.Header{}
	if token != "" {
		h.Set("Authorization", "Bearer "+token)
	}
	return websocket.DefaultDialer.Dial(url, h)
}

func wsSend(t *testing.T, c *websocket.Conn, typ string, data interface{}) {
	t.Helper()
	msg := map[string]interface{}{"type": typ, "data": data}
	if err := c.WriteJSON(msg); err != nil {
		t.Fatal(err)
	}
}

// wsWait читает сообщения, пока не встретит нужный type (с таймаутом)
func wsWait(t *testing.T, c *websocket.Conn, typ string) map[string]interface{} {
	t.Helper()
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		var msg map[string]interface{}
		if err := c.ReadJSON(&msg); err != nil {
			t.Fatalf("waiting for %q: %v", typ, err)
		}
		if msg["type"] == typ {
			return msg
		}
	}
}

// ============ Регистрация / логин ============

func TestRegisterAndLoginFlow(t *testing.T) {
	env := newTestEnv(t, nil)

	tokenA, aliceID := env.register("alice", "alice-password", "alice-phone", pubkey(1))
	if tokenA == "" || aliceID == 0 {
		t.Fatal("expected token and user id")
	}

	// Второй пользователь — не админ, партнёр первого
	out := env.doJSON("POST", "/api/register", "", map[string]interface{}{
		"username": "bob", "password": "bob-password-1", "device_id": "bob-pc", "public_key": pubkey(2),
	}, http.StatusOK)
	if out["is_admin"].(bool) {
		t.Error("second user must not be admin")
	}

	// Третий — лимит
	env.doJSON("POST", "/api/register", "", map[string]interface{}{
		"username": "carol", "password": "carol-password", "device_id": "carol-dev",
	}, http.StatusForbidden)

	// Партнёр
	partner := env.doJSON("GET", "/api/partner", tokenA, nil, http.StatusOK)
	if partner["username"] != "bob" {
		t.Errorf("expected partner bob, got %v", partner)
	}

	// Логин
	resp, data := env.login("alice", "alice-password", "alice-phone")
	if resp.StatusCode != http.StatusOK || data["token"] == "" {
		t.Fatalf("login failed: %d %v", resp.StatusCode, data)
	}
	if data["partner_username"] != "bob" {
		t.Errorf("login must return partner, got %v", data)
	}

	// Неверный пароль
	resp, _ = env.login("alice", "wrong-password", "alice-phone")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("expected 401 for wrong password, got %d", resp.StatusCode)
	}

	// Несуществующий пользователь — тот же ответ
	resp, _ = env.login("nobody", "whatever-pass", "alice-phone")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("expected 401 for unknown user, got %d", resp.StatusCode)
	}
}

func TestRegisterValidation(t *testing.T) {
	env := newTestEnv(t, nil)

	cases := []struct {
		name string
		body map[string]interface{}
	}{
		{"short password", map[string]interface{}{"username": "alice", "password": "short", "device_id": "d1"}},
		{"bad username", map[string]interface{}{"username": "al ice!", "password": "long-enough-pw", "device_id": "d1"}},
		{"bad device id", map[string]interface{}{"username": "alice", "password": "long-enough-pw", "device_id": "../etc"}},
		{"bad public key", map[string]interface{}{"username": "alice", "password": "long-enough-pw", "device_id": "d1", "public_key": []byte{1, 2, 3}}},
		{"empty", map[string]interface{}{}},
	}
	for _, c := range cases {
		resp, _ := env.do("POST", "/api/register", "", c.body)
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("%s: expected 400, got %d", c.name, resp.StatusCode)
		}
	}

	// Слишком большое тело
	big := bytes.Repeat([]byte("a"), maxJSONBody+10)
	req, _ := http.NewRequest("POST", env.http.URL+"/api/register", bytes.NewReader(big))
	resp, _ := http.DefaultClient.Do(req)
	if resp.StatusCode != http.StatusRequestEntityTooLarge && resp.StatusCode != http.StatusBadRequest {
		t.Errorf("expected 413/400 for oversized body, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestPassTheHashRejected(t *testing.T) {
	env := newTestEnv(t, nil)
	env.register("alice", "alice-password", "alice-phone", pubkey(1))

	user, err := env.srv.db.GetUserByUsername("alice")
	if err != nil || user == nil {
		t.Fatal("user not found")
	}

	// Раньше fallback «plaintext == stored hash» пускал по самому bcrypt-хэшу
	resp, _ := env.login("alice", user.PasswordHash, "alice-phone")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("login with password hash must be rejected, got %d", resp.StatusCode)
	}
}

func TestDuplicateDeviceRejected(t *testing.T) {
	env := newTestEnv(t, nil)
	env.register("alice", "alice-password", "shared-device", pubkey(1))

	// Второй пользователь пытается зарегистрироваться с чужим device_id
	resp, _ := env.do("POST", "/api/register", "", map[string]interface{}{
		"username": "bob", "password": "bob-password-1", "device_id": "shared-device",
	})
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("expected 409 for duplicate device, got %d", resp.StatusCode)
	}

	// Устройство осталось у alice
	dev, _ := env.srv.db.GetDeviceByID("shared-device")
	alice, _ := env.srv.db.GetUserByUsername("alice")
	if dev.UserID != alice.ID {
		t.Error("device must remain bound to original user")
	}

	// bob регистрируется нормально, затем логинится с device_id alice → 403
	env.register("bob", "bob-password-1", "bob-device", pubkey(2))
	resp, _ = env.login("bob", "bob-password-1", "shared-device")
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected 403 for login with another user's device, got %d", resp.StatusCode)
	}
}

func TestLoginRateLimit(t *testing.T) {
	env := newTestEnv(t, nil)
	env.register("alice", "alice-password", "alice-phone", pubkey(1))

	var got429 bool
	for i := 0; i < loginUserFailures+2; i++ {
		resp, _ := env.login("alice", "wrong-password", "alice-phone")
		if resp.StatusCode == http.StatusTooManyRequests {
			if resp.Header.Get("Retry-After") == "" {
				t.Error("429 must carry Retry-After")
			}
			got429 = true
			break
		}
	}
	if !got429 {
		t.Fatal("expected 429 after repeated failures")
	}

	// Даже правильный пароль не проходит, пока действует блокировка
	resp, _ := env.login("alice", "alice-password", "alice-phone")
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Errorf("expected 429 while blocked, got %d", resp.StatusCode)
	}
}

func TestDuressPasswordTriggersWipe(t *testing.T) {
	env := newTestEnv(t, nil)
	env.register("alice", "alice-password", "alice-phone", pubkey(1))

	resp, _ := env.login("alice", "correct-horse-battery-staple", "alice-phone")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("duress login must look like a failed login, got %d", resp.StatusCode)
	}

	deadline := time.Now().Add(5 * time.Second)
	for atomic.LoadInt32(&env.exitCalls) == 0 && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if atomic.LoadInt32(&env.exitCalls) != 1 {
		t.Fatalf("expected wipe + exit once, got %d", env.exitCalls)
	}
	if _, err := os.Stat(filepath.Join(env.dataDir, "messages.db")); !os.IsNotExist(err) {
		t.Error("database must be removed after wipe")
	}
}

// ============ Сессии: logout, revoke, header-only ============

func TestAuthHeaderOnly(t *testing.T) {
	env := newTestEnv(t, nil)
	token, _ := env.register("alice", "alice-password", "alice-phone", pubkey(1))

	// Токен в query — больше не принимается
	resp, _ := env.do("GET", "/api/devices?token="+token, "", nil)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("query token must be rejected, got %d", resp.StatusCode)
	}

	// X-Session-Token принимается
	req, _ := http.NewRequest("GET", env.http.URL+"/api/devices", nil)
	req.Header.Set("X-Session-Token", token)
	r2, _ := http.DefaultClient.Do(req)
	r2.Body.Close()
	if r2.StatusCode != http.StatusOK {
		t.Errorf("X-Session-Token must be accepted, got %d", r2.StatusCode)
	}

	// Мусорный токен — общий ответ без деталей
	resp, body := env.do("GET", "/api/devices", "not-a-real-token", nil)
	if resp.StatusCode != http.StatusUnauthorized || strings.Contains(string(body), "invalid token") {
		t.Errorf("expected generic 401, got %d %q", resp.StatusCode, body)
	}

	// WS без токена
	if _, wsResp, err := env.wsDial("", ""); err == nil || wsResp == nil || wsResp.StatusCode != http.StatusUnauthorized {
		t.Errorf("ws without token must fail with 401")
	}
}

func TestLogoutInvalidatesTokenAndWS(t *testing.T) {
	env := newTestEnv(t, nil)
	token, _ := env.register("alice", "alice-password", "alice-phone", pubkey(1))

	conn, _, err := env.wsDial(token, "alice-phone")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	env.doJSON("POST", "/api/logout", token, nil, http.StatusOK)

	resp, _ := env.do("GET", "/api/devices", token, nil)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("token must be invalid after logout, got %d", resp.StatusCode)
	}

	// WS соединение должно быть закрыто сервером
	conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			break
		}
	}

	// Ключи устройства не трогаем — повторный логин тем же device_id работает
	r, _ := env.login("alice", "alice-password", "alice-phone")
	if r.StatusCode != http.StatusOK {
		t.Errorf("re-login after logout must work, got %d", r.StatusCode)
	}
}

func TestRevokeDeviceKillsSessions(t *testing.T) {
	env := newTestEnv(t, nil)
	tokenPhone, _ := env.register("alice", "alice-password", "alice-phone", pubkey(1))

	// Привязываем второе устройство через код
	link := env.doJSON("POST", "/api/devices/link/create", tokenPhone, map[string]interface{}{}, http.StatusOK)
	code := link["link_code"].(string)

	done := env.doJSON("POST", "/api/devices/link/complete", "", map[string]interface{}{
		"link_code": code, "device_id": "alice-pc", "device_name": "PC", "device_type": "windows", "public_key": pubkey(1),
	}, http.StatusOK)
	tokenPC := done["token"].(string)

	// Код одноразовый
	env.doJSON("POST", "/api/devices/link/complete", "", map[string]interface{}{
		"link_code": code, "device_id": "alice-tablet",
	}, http.StatusBadRequest)

	// Оба устройства видны
	list := env.doJSON("GET", "/api/devices", tokenPC, nil, http.StatusOK)
	if n := len(list["devices"].([]interface{})); n != 2 {
		t.Fatalf("expected 2 devices, got %d", n)
	}

	// Отзываем ПК с телефона
	env.doJSON("POST", "/api/devices/revoke", tokenPhone, map[string]interface{}{"device_id": "alice-pc"}, http.StatusOK)

	// Токен ПК больше не работает — 403 (устройство отозвано), WS тоже
	resp, _ := env.do("GET", "/api/devices", tokenPC, nil)
	if resp.StatusCode != http.StatusForbidden {
		t.Errorf("revoked device token must get 403, got %d", resp.StatusCode)
	}
	if _, wsResp, err := env.wsDial(tokenPC, "alice-pc"); err == nil || wsResp == nil || wsResp.StatusCode != http.StatusForbidden {
		t.Errorf("revoked device must not open ws")
	}

	// Логин паролем с отозванного устройства тоже невозможен
	r, _ := env.login("alice", "alice-password", "alice-pc")
	if r.StatusCode != http.StatusForbidden {
		t.Errorf("login from revoked device must be 403, got %d", r.StatusCode)
	}

	// Телефон работает
	env.doJSON("GET", "/api/devices", tokenPhone, nil, http.StatusOK)
}

func TestLinkCodeRateLimit(t *testing.T) {
	env := newTestEnv(t, nil)

	var got429 bool
	for i := 0; i < linkCodeFailures+2; i++ {
		resp, _ := env.do("POST", "/api/devices/link/complete", "", map[string]interface{}{
			"link_code": "AAAA-BBBB", "device_id": fmt.Sprintf("dev-%d", i),
		})
		if resp.StatusCode == http.StatusTooManyRequests {
			got429 = true
			break
		}
	}
	if !got429 {
		t.Fatal("expected 429 after brute-forcing link codes")
	}
}

func TestSlidingSessionExpiry(t *testing.T) {
	env := newTestEnv(t, nil)
	token, _ := env.register("alice", "alice-password", "alice-phone", pubkey(1))

	// Искусственно приближаем срок истечения
	soon := time.Now().Add(24 * time.Hour).Unix()
	if _, err := env.srv.db.ExtendSession(hashToken(token), 24*time.Hour); err != nil {
		t.Fatal(err)
	}

	env.doJSON("GET", "/api/devices", token, nil, http.StatusOK)

	sess, _ := env.srv.db.GetSessionByTokenHash(hashToken(token))
	if sess.ExpiresAt <= soon+60 {
		t.Errorf("active session must be extended, got %d (was %d)", sess.ExpiresAt, soon)
	}

	// Истёкшая сессия — 401
	env.srv.db.ExtendSession(hashToken(token), -time.Hour)
	resp, _ := env.do("GET", "/api/devices", token, nil)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("expired session must be 401, got %d", resp.StatusCode)
	}
}

// ============ Файлы ============

func (e *testEnv) upload(token string, content []byte, extraField bool) (*http.Response, map[string]interface{}) {
	e.t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	if extraField {
		mw.WriteField("file_name", "c2VjcmV0LnR4dA==")
		mw.WriteField("mime_type", "text/plain")
	}
	fw, _ := mw.CreateFormFile("file", "encrypted_file")
	fw.Write(content)
	mw.Close()

	req, _ := http.NewRequest("POST", e.http.URL+"/api/files/upload", &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	var out map[string]interface{}
	json.Unmarshal(data, &out)
	return resp, out
}

func TestFileUploadDownload(t *testing.T) {
	env := newTestEnv(t, nil)
	tokenA, _ := env.register("alice", "alice-password", "alice-phone", pubkey(1))
	tokenB, _ := env.register("bob", "bob-password-1", "bob-pc", pubkey(2))

	content := bytes.Repeat([]byte("encrypted-blob-"), 1000)
	resp, out := env.upload(tokenA, content, true)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("upload failed: %d %v", resp.StatusCode, out)
	}
	fileID := out["file_id"].(string)
	if !fileIDRe.MatchString(fileID) {
		t.Fatalf("unexpected file id %q", fileID)
	}

	// Файл лежит в storage_path из конфига
	if _, err := os.Stat(filepath.Join(env.srv.storagePath, fileID)); err != nil {
		t.Errorf("file must be stored under configured storage path: %v", err)
	}
	if _, err := os.Stat("./data/files/" + fileID); err == nil {
		t.Error("file must not be written to hardcoded ./data/files")
	}

	// Имя/MIME в открытом виде не сохранены
	f, _ := env.srv.db.GetFileByID(fileID)
	if len(f.FileNameEncrypted) != 0 || f.MimeType != "application/octet-stream" {
		t.Errorf("plaintext metadata must not be stored: %+v", f)
	}

	// Скачивание партнёром
	r, data := env.do("GET", "/api/files/"+fileID, tokenB, nil)
	if r.StatusCode != http.StatusOK || !bytes.Equal(data, content) {
		t.Fatalf("partner download failed: %d (%d bytes)", r.StatusCode, len(data))
	}
	if r.Header.Get("Content-Type") != "application/octet-stream" || r.Header.Get("X-Content-Type-Options") != "nosniff" {
		t.Errorf("unexpected download headers: %v", r.Header)
	}

	// Range через ServeContent
	req, _ := http.NewRequest("GET", env.http.URL+"/api/files/"+fileID, nil)
	req.Header.Set("Authorization", "Bearer "+tokenA)
	req.Header.Set("Range", "bytes=0-9")
	rr, _ := http.DefaultClient.Do(req)
	part, _ := io.ReadAll(rr.Body)
	rr.Body.Close()
	if rr.StatusCode != http.StatusPartialContent || !bytes.Equal(part, content[:10]) {
		t.Errorf("range request failed: %d %q", rr.StatusCode, part)
	}

	// Info
	info := env.doJSON("GET", "/api/files/"+fileID+"/info", tokenA, nil, http.StatusOK)
	if int64(info["file_size"].(float64)) != int64(len(content)) {
		t.Errorf("unexpected file info %v", info)
	}

	// Невалидный id / без авторизации
	if r, _ := env.do("GET", "/api/files/../../etc/passwd", tokenA, nil); r.StatusCode != http.StatusBadRequest && r.StatusCode != http.StatusNotFound && r.StatusCode != http.StatusMovedPermanently {
		t.Errorf("path traversal id must be rejected, got %d", r.StatusCode)
	}
	if r, _ := env.do("GET", "/api/files/"+fileID, "", nil); r.StatusCode != http.StatusUnauthorized {
		t.Errorf("download without auth must be 401, got %d", r.StatusCode)
	}
}

func TestFileUploadLimits(t *testing.T) {
	env := newTestEnv(t, nil) // max file 1 MB, quota 2 MB
	token, _ := env.register("alice", "alice-password", "alice-phone", pubkey(1))

	// Больше лимита одного файла → 413
	resp, _ := env.upload(token, make([]byte, (1<<20)+1), false)
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413 for oversized file, got %d", resp.StatusCode)
	}
	if parts, _ := filepath.Glob(filepath.Join(env.srv.storagePath, "*.part")); len(parts) != 0 {
		t.Errorf("temp files must be cleaned up: %v", parts)
	}

	// Пустой файл → 400
	resp, _ = env.upload(token, nil, false)
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("expected 400 for empty file, got %d", resp.StatusCode)
	}

	// Заполняем квоту: 2 файла по ~0.9 MB → третий не влезает → 507
	for i := 0; i < 2; i++ {
		resp, out := env.upload(token, make([]byte, 900<<10), false)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("upload %d failed: %d %v", i, resp.StatusCode, out)
		}
	}
	resp, _ = env.upload(token, make([]byte, 900<<10), false)
	if resp.StatusCode != http.StatusInsufficientStorage {
		t.Fatalf("expected 507 when quota exceeded, got %d", resp.StatusCode)
	}
	if entries, _ := os.ReadDir(env.srv.storagePath); len(entries) != 2 {
		t.Errorf("rejected upload must not leave files, got %d entries", len(entries))
	}
}

// ============ WebSocket ============

func TestWebSocketMessaging(t *testing.T) {
	env := newTestEnv(t, nil)
	tokenA, aliceID := env.register("alice", "alice-password", "alice-phone", pubkey(1))
	tokenB, bobID := env.register("bob", "bob-password-1", "bob-pc", pubkey(2))

	wsA, _, err := env.wsDial(tokenA, "alice-phone")
	if err != nil {
		t.Fatal(err)
	}
	defer wsA.Close()
	wsB, _, err := env.wsDial(tokenB, "bob-pc")
	if err != nil {
		t.Fatal(err)
	}
	defer wsB.Close()

	// device_id другого устройства в query → 403
	if _, resp, err := env.wsDial(tokenA, "bob-pc"); err == nil || resp == nil || resp.StatusCode != http.StatusForbidden {
		t.Error("device_id mismatch must be rejected")
	}

	// Отправка с client_id
	wsSend(t, wsA, "send_message", map[string]interface{}{
		"recipient_id":      bobID,
		"encrypted_content": []byte("ciphertext-1"),
		"content_type":      "encrypted",
		"client_id":         "local-42",
	})
	sent := wsWait(t, wsA, "message_sent")
	sentData := sent["data"].(map[string]interface{})
	if sentData["client_id"] != "local-42" {
		t.Errorf("message_sent must echo client_id, got %v", sentData)
	}
	seq := int64(sentData["seq_id"].(float64))

	newMsg := wsWait(t, wsB, "new_message")
	nd := newMsg["data"].(map[string]interface{})
	if int64(nd["seq_id"].(float64)) != seq || int64(nd["sender_id"].(float64)) != aliceID {
		t.Errorf("unexpected new_message %v", nd)
	}

	// Валидация
	wsSend(t, wsA, "send_message", map[string]interface{}{
		"recipient_id": bobID, "encrypted_content": []byte("x"), "content_type": "Bad Type!",
	})
	if e := wsWait(t, wsA, "error"); e["data"].(map[string]interface{})["code"] != "invalid_data" {
		t.Errorf("expected invalid_data error, got %v", e)
	}
	wsSend(t, wsA, "send_message", map[string]interface{}{
		"recipient_id": bobID, "encrypted_content": []byte("x"), "content_type": "encrypted_file", "file_id": "deadbeefdeadbeefdeadbeefdeadbeef",
	})
	if e := wsWait(t, wsA, "error"); e["data"].(map[string]interface{})["code"] != "file_not_found" {
		t.Errorf("expected file_not_found error, got %v", e)
	}
	wsSend(t, wsA, "send_message", map[string]interface{}{
		"recipient_id": aliceID, "encrypted_content": []byte("x"), "content_type": "encrypted",
	})
	if e := wsWait(t, wsA, "error"); e["data"].(map[string]interface{})["code"] != "invalid_recipient" {
		t.Errorf("expected invalid_recipient error, got %v", e)
	}

	// ack от ОТПРАВИТЕЛЯ игнорируется (проверяем по БД после round-trip через ping),
	// от получателя — проходит
	wsSend(t, wsA, "ack", map[string]interface{}{"seq_id": seq})
	wsSend(t, wsA, "ping", nil)
	wsWait(t, wsA, "pong")
	stored, _ := env.srv.db.GetMessageBySeqID(seq)
	if st, _ := env.srv.db.GetMessageStatus(stored.ID, "alice-phone"); st != "" {
		t.Errorf("sender must not be able to set delivery status, got %q", st)
	}

	wsSend(t, wsB, "read", map[string]interface{}{"seq_id": seq})
	su := wsWait(t, wsA, "status_update")
	if su["data"].(map[string]interface{})["status"] != "read" {
		t.Errorf("expected read status, got %v", su)
	}
	if st, _ := env.srv.db.GetMessageStatus(stored.ID, "bob-pc"); st != "read" {
		t.Errorf("expected stored status read, got %q", st)
	}

	// Удаление → tombstone в forward sync
	wsSend(t, wsB, "delete", map[string]interface{}{"seq_id": seq})
	if e := wsWait(t, wsB, "error"); e["data"].(map[string]interface{})["code"] != "forbidden" {
		t.Errorf("recipient must not delete sender's message, got %v", e)
	}
	wsSend(t, wsA, "delete", map[string]interface{}{"seq_id": seq})
	wsWait(t, wsB, "message_deleted")

	wsSend(t, wsB, "sync", map[string]interface{}{"since_seq_id": 0})
	syncResp := wsWait(t, wsB, "sync_response")
	sd := syncResp["data"].(map[string]interface{})
	if sd["direction"] != "forward" {
		t.Errorf("sync_response must include direction, got %v", sd)
	}
	msgs := sd["messages"].([]interface{})
	if len(msgs) != 1 {
		t.Fatalf("expected tombstone in forward sync, got %d messages", len(msgs))
	}
	tomb := msgs[0].(map[string]interface{})
	if tomb["is_deleted"] != true {
		t.Errorf("expected tombstone, got %v", tomb)
	}
	if c, ok := tomb["encrypted_content"]; ok && c != nil && c != "" {
		t.Errorf("tombstone must not carry content: %v", c)
	}

	// Backward sync
	wsSend(t, wsB, "sync", map[string]interface{}{"before_seq_id": seq + 1})
	back := wsWait(t, wsB, "sync_response")
	if back["data"].(map[string]interface{})["direction"] != "backward" {
		t.Error("expected backward direction")
	}

	// ping/time_sync
	wsSend(t, wsA, "ping", nil)
	wsWait(t, wsA, "pong")
}

func TestWebSocketDuplicateConnectionsDoNotCrash(t *testing.T) {
	env := newTestEnv(t, nil)
	tokenA, _ := env.register("alice", "alice-password", "alice-phone", pubkey(1))
	_, bobID := env.register("bob", "bob-password-1", "bob-pc", pubkey(2))

	// Много параллельных подключений одним device_id + поток сообщений:
	// раньше это роняло сервер (send on closed channel)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 5; j++ {
				conn, _, err := env.wsDial(tokenA, "alice-phone")
				if err != nil {
					continue
				}
				for k := 0; k < 3; k++ {
					conn.WriteJSON(map[string]interface{}{"type": "ping"})
					conn.WriteJSON(map[string]interface{}{"type": "send_message", "data": map[string]interface{}{
						"recipient_id": bobID, "encrypted_content": []byte("x"), "content_type": "encrypted",
					}})
				}
				conn.Close()
			}
		}()
	}
	wg.Wait()

	// Сервер жив
	env.doJSON("GET", "/health", "", nil, http.StatusOK)
	conn, _, err := env.wsDial(tokenA, "alice-phone")
	if err != nil {
		t.Fatalf("server must still accept connections: %v", err)
	}
	conn.Close()
}

// ============ Dead Man's Switch ============

func TestDeadManSwitchUsesDeviceActivity(t *testing.T) {
	env := newTestEnv(t, func(c *config.Config) {
		c.DeadMan.Enabled = true
		c.DeadMan.TimeoutDays = 10
	})
	_, aliceID := env.register("alice", "alice-password", "alice-phone", pubkey(1))

	now := time.Now()
	if env.srv.deadManShouldTrigger(now) {
		t.Fatal("fresh admin must not trigger")
	}

	// Пользователь «не логинился» 20 дней, но устройство было активно вчера
	old := now.Add(-20 * 24 * time.Hour).Unix()
	env.srv.db.Exec(`UPDATE users SET last_seen = ? WHERE id = ?`, old, aliceID)
	env.srv.db.Exec(`UPDATE devices SET last_seen = ? WHERE user_id = ?`, now.Add(-24*time.Hour).Unix(), aliceID)
	if env.srv.deadManShouldTrigger(now) {
		t.Fatal("recent device activity must prevent trigger")
	}

	env.srv.db.Exec(`UPDATE devices SET last_seen = ? WHERE user_id = ?`, old, aliceID)
	if !env.srv.deadManShouldTrigger(now) {
		t.Fatal("expected trigger after timeout")
	}
}
