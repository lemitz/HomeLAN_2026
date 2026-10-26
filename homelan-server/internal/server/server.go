// Package server — HTTP/WebSocket API сервера HomeLAN.
package server

import (
	"context"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"golang.org/x/crypto/bcrypt"
	"homelan-server/internal/config"
	"homelan-server/internal/db"
	"homelan-server/internal/linking"
	"homelan-server/internal/panic"
	"homelan-server/internal/ratelimit"
	"homelan-server/internal/ws"
)

// Panicker — то, что умеет запускать экстренный вайп.
type Panicker interface {
	Trigger(reason panic.Reason)
}

type Server struct {
	cfg    *config.Config
	db     *db.Database
	hub    *ws.Hub
	links  *linking.LinkingService
	panic  Panicker
	authRL *ratelimit.Limiter // логин, регистрация, panic
	linkRL *ratelimit.Limiter // завершение привязки

	upgrader  websocket.Upgrader
	dummyHash []byte
	httpSrv   *http.Server

	activityMu   sync.Mutex
	lastActivity map[string]time.Time

	stop     chan struct{}
	stopOnce sync.Once
}

// New создаёт сервер поверх открытой БД.
func New(cfg *config.Config, database *db.Database, panicker Panicker) *Server {
	dummy, _ := bcrypt.GenerateFromPassword([]byte("homelan-timing-equalizer"), bcrypt.DefaultCost)
	s := &Server{
		cfg:          cfg,
		db:           database,
		hub:          ws.NewHub(database),
		links:        linking.NewLinkingService(),
		panic:        panicker,
		authRL:       ratelimit.New(5, 15*time.Minute, 15*time.Minute),
		linkRL:       ratelimit.New(10, 15*time.Minute, 15*time.Minute),
		dummyHash:    dummy,
		lastActivity: make(map[string]time.Time),
		stop:         make(chan struct{}),
		upgrader: websocket.Upgrader{
			ReadBufferSize:  4096,
			WriteBufferSize: 4096,
			// Нативные клиенты не присылают Origin. Запросы из браузера
			// (с Origin) отвергаются — защита от cross-site WebSocket hijacking.
			CheckOrigin: func(r *http.Request) bool { return r.Header.Get("Origin") == "" },
		},
	}
	s.hub.OnActivity = s.touchActivity
	s.hub.OnFileReleased = s.releaseFile
	return s
}

// Handler возвращает HTTP-обработчик со всеми маршрутами.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /api/time", s.handleHealth)

	mux.HandleFunc("POST /api/register", s.handleRegister)
	mux.HandleFunc("POST /api/login", s.handleLogin)
	mux.HandleFunc("POST /api/logout", s.auth(s.handleLogout))
	mux.HandleFunc("GET /api/session", s.auth(s.handleSession))

	mux.HandleFunc("GET /api/partner", s.auth(s.handlePartner))
	mux.HandleFunc("GET /api/users/{id}", s.auth(s.handleGetUser))

	mux.HandleFunc("GET /api/devices", s.auth(s.handleDevicesList))
	mux.HandleFunc("POST /api/devices/revoke", s.auth(s.handleDeviceRevoke))
	mux.HandleFunc("POST /api/devices/link/create", s.auth(s.handleLinkCreate))
	mux.HandleFunc("POST /api/devices/link/complete", s.handleLinkComplete)

	mux.HandleFunc("POST /api/files/upload", s.auth(s.handleFileUpload))
	mux.HandleFunc("GET /api/files/{id}", s.auth(s.handleFileDownload))

	mux.HandleFunc("POST /api/panic", s.auth(s.handlePanic))

	mux.HandleFunc("GET /ws", s.auth(s.handleWebSocket))
	return mux
}

// Start запускает фоновые задачи и HTTP-сервер (блокируется).
func (s *Server) Start() error {
	go s.maintenanceLoop()
	if s.cfg.DeadMan.Enabled {
		go s.deadManSwitchLoop()
	}

	addr := fmt.Sprintf("%s:%d", s.cfg.Server.Host, s.cfg.Server.Port)
	s.httpSrv = &http.Server{
		Addr:              addr,
		Handler:           s.Handler(),
		ReadHeaderTimeout: 15 * time.Second,
		ReadTimeout:       time.Duration(s.cfg.Timeouts.ReadSeconds) * time.Second,
		WriteTimeout:      time.Duration(s.cfg.Timeouts.WriteSeconds) * time.Second,
		IdleTimeout:       time.Duration(s.cfg.Timeouts.IdleSeconds) * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
	log.Printf("🚀 HomeLAN Server listening on %s", addr)
	if err := s.httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
}

// Shutdown корректно останавливает сервер.
func (s *Server) Shutdown(ctx context.Context) error {
	s.stopOnce.Do(func() { close(s.stop) })
	s.links.Close()
	s.hub.CloseAll()
	if s.httpSrv != nil {
		return s.httpSrv.Shutdown(ctx)
	}
	return nil
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":      "ok",
		"server_time": time.Now().Unix(),
		"protocol":    2,
	})
}

// touchActivity обновляет last_seen пользователя и устройства не чаще раза в 5 минут.
func (s *Server) touchActivity(userID int64, deviceID string) {
	key := fmt.Sprintf("%d/%s", userID, deviceID)
	s.activityMu.Lock()
	last := s.lastActivity[key]
	due := time.Since(last) > 5*time.Minute
	if due {
		s.lastActivity[key] = time.Now()
	}
	s.activityMu.Unlock()
	if !due {
		return
	}
	if err := s.db.TouchUser(userID); err != nil {
		log.Printf("touch user: %v", err)
	}
	if err := s.db.TouchDevice(deviceID); err != nil {
		log.Printf("touch device: %v", err)
	}
}

// releaseFile удаляет файл, который больше не нужен.
func (s *Server) releaseFile(fileID string) {
	path, err := s.db.MarkFileDeleted(fileID)
	if err != nil {
		log.Printf("release file %s: %v", fileID, err)
		return
	}
	if path != "" {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			log.Printf("remove file %s: %v", path, err)
		}
	}
}

func (s *Server) maintenanceLoop() {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		s.runMaintenance()
		select {
		case <-s.stop:
			return
		case <-ticker.C:
		}
	}
}

func (s *Server) runMaintenance() {
	msgs, files, err := s.db.DeleteExpiredMessages()
	if err != nil {
		log.Printf("expire messages: %v", err)
	}
	for _, m := range msgs {
		s.hub.PublishMessage(m)
	}
	for _, f := range files {
		s.releaseFile(f)
	}
	if len(msgs) > 0 {
		log.Printf("🧹 Expired %d messages", len(msgs))
	}

	paths, err := s.db.CollectGarbageFiles(24 * time.Hour)
	if err != nil {
		log.Printf("collect files: %v", err)
	}
	for _, p := range paths {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			log.Printf("remove file %s: %v", p, err)
		}
	}
	if n, err := s.db.DeleteStaleSessions(); err == nil && n > 0 {
		log.Printf("🧹 Removed %d stale sessions", n)
	}
}

func (s *Server) deadManSwitchLoop() {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-s.stop:
			return
		case <-ticker.C:
		}
		s.checkDeadMan(time.Now())
	}
}

// checkDeadMan запускает вайп, если админ неактивен дольше timeout_days.
func (s *Server) checkDeadMan(now time.Time) {
	// Orange Pi без RTC-батарейки может стартовать с 1970 годом.
	if now.Year() < 2024 {
		log.Printf("⚠️ Invalid system time, skipping dead man's switch check")
		return
	}
	admin, err := s.db.GetAdmin()
	if err != nil || admin == nil {
		return
	}
	last, err := s.db.LastActivity(admin.ID)
	if err != nil || last == 0 {
		return
	}
	idle := now.Sub(time.Unix(last, 0))
	if idle > time.Duration(s.cfg.DeadMan.TimeoutDays)*24*time.Hour {
		log.Printf("💀 Dead Man's Switch: admin inactive for %.1f days", idle.Hours()/24)
		s.panic.Trigger(panic.ReasonDeadMan)
	}
}

// WatchUSB следит за наличием ключа на флешке и запускает вайп при его пропаже.
func (s *Server) WatchUSB(keyPath string) {
	log.Printf("👀 Watching USB key at: %s", keyPath)
	check := func() error {
		f, err := os.Open(keyPath)
		if err != nil {
			return err
		}
		defer f.Close()
		// Чтение байта заставляет ОС реально обратиться к накопителю.
		buf := make([]byte, 1)
		if _, err := f.Read(buf); err != nil && err != io.EOF {
			return err
		}
		return nil
	}

	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-s.stop:
			return
		case <-ticker.C:
		}
		if check() == nil {
			continue
		}
		// Защита от кратковременных сбоев питания/шины: 3 повтора по 50 мс.
		missing := true
		for i := 0; i < 3; i++ {
			time.Sleep(50 * time.Millisecond)
			if check() == nil {
				log.Printf("✅ USB recovered after glitch")
				missing = false
				break
			}
		}
		if missing {
			log.Printf("🚨 USB key removed")
			s.panic.Trigger(panic.ReasonUSBRemoved)
			return
		}
	}
}
