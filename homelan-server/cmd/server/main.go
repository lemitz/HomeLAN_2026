package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
	"homelan-server/internal/config"
	"homelan-server/internal/db"
	"homelan-server/internal/linking"
	"homelan-server/internal/mdns"
	wipe "homelan-server/internal/panic"
	"homelan-server/internal/ratelimit"
	"homelan-server/internal/usb"
	"homelan-server/internal/ws"
)

// Version — единая версия сервера (используется в логах и mDNS TXT-записи)
const Version = "0.5.0"

const (
	sessionDuration       = 30 * 24 * time.Hour // срок жизни сессии
	sessionRenewThreshold = 15 * 24 * time.Hour // продлевать, если осталось меньше
	sessionPruneAge       = 7 * 24 * time.Hour  // хранить истёкшие/отозванные сессии не дольше

	// Защита от перебора: 5 неудачных попыток на пару ip+username, 30 неудачных с одного IP
	loginUserFailures = 5
	loginIPFailures   = 30
	loginBaseDelay    = 30 * time.Second
	loginMaxDelay     = 15 * time.Minute

	linkCodeFailures = 10
)

type Server struct {
	config         *config.Config
	db             *db.Database
	hub            *ws.Hub
	upgrader       websocket.Upgrader
	masterKey      []byte
	keyPath        string
	panicHandler   *wipe.PanicHandler
	linkingService *linking.LinkingService
	mdnsServer     *mdns.MDNSServer

	storagePath string
	maxFileSize int64
	maxStorage  int64

	loginUserLimiter *ratelimit.Limiter
	loginIPLimiter   *ratelimit.Limiter
	linkLimiter      *ratelimit.Limiter

	// registerMu сериализует регистрацию: проверка max_users/admin и вставка
	// должны быть атомарны относительно друг друга.
	registerMu sync.Mutex

	// exitFunc вызывается после завершения panic wipe (в тестах подменяется)
	exitFunc func()
}

func NewServer(cfg *config.Config, masterKey []byte, keyPath string) (*Server, error) {
	storagePath, err := filepath.Abs(cfg.Files.StoragePath)
	if err != nil {
		return nil, fmt.Errorf("invalid storage path: %w", err)
	}
	if err := os.MkdirAll(storagePath, 0700); err != nil {
		return nil, fmt.Errorf("failed to create storage directory: %w", err)
	}

	database, err := db.New(cfg.Database.Path, masterKey)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to database: %w", err)
	}

	s := &Server{
		config:           cfg,
		db:               database,
		hub:              ws.NewHub(database),
		masterKey:        masterKey,
		keyPath:          keyPath,
		linkingService:   linking.NewLinkingService(),
		storagePath:      storagePath,
		maxFileSize:      cfg.MaxFileSizeBytes(),
		maxStorage:       cfg.MaxStorageBytes(),
		loginUserLimiter: ratelimit.New(loginUserFailures, loginBaseDelay, loginMaxDelay),
		loginIPLimiter:   ratelimit.New(loginIPFailures, loginBaseDelay, loginMaxDelay),
		linkLimiter:      ratelimit.New(linkCodeFailures, loginBaseDelay, loginMaxDelay),
		exitFunc:         func() { os.Exit(1) },
		upgrader: websocket.Upgrader{
			ReadBufferSize:  1024,
			WriteBufferSize: 1024,
			// CheckOrigin не задан: gorilla по умолчанию пропускает запросы без Origin
			// (нативные клиенты) и требует совпадения Origin с Host для браузеров.
		},
	}

	// Путь к БД и хранилищу для вайпа берём из конфига — те же, что использует
	// сервер. Раньше аплоад писал в захардкоженный ./data/files, и при смене
	// storage_path в конфиге вайп не трогал реальные файлы.
	s.panicHandler = wipe.New(database, cfg.Database.Path, storagePath, func() { s.exitFunc() })

	return s, nil
}

// routes собирает HTTP-маршруты (вынесено отдельно для тестов)
func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/api/register", s.handleRegister)
	mux.HandleFunc("/api/login", s.handleLogin)
	mux.HandleFunc("/api/logout", s.handleLogout)
	mux.HandleFunc("/api/time", s.handleTime)
	mux.HandleFunc("/api/user/", s.handleGetUser)
	mux.HandleFunc("/api/partner", s.handleGetPartner)
	mux.HandleFunc("/ws", s.handleWebSocket)
	mux.HandleFunc("/api/files/upload", s.handleFileUpload)
	mux.HandleFunc("/api/files/", s.handleFiles)
	mux.HandleFunc("/api/panic", s.handlePanic)

	// Device Linking
	mux.HandleFunc("/api/devices/link/create", s.handleLinkCreate)
	mux.HandleFunc("/api/devices/link/complete", s.handleLinkComplete)
	mux.HandleFunc("/api/devices", s.handleDevicesList)
	mux.HandleFunc("/api/devices/revoke", s.handleDeviceRevoke)

	return secureHeaders(mux)
}

// secureHeaders добавляет базовые защитные заголовки ко всем ответам
func secureHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Cache-Control", "no-store")
		h.Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) startMDNS() {
	mdnsServer, err := mdns.New(s.config.Server.Port, Version)
	if err != nil {
		log.Printf("⚠️ mDNS failed to start: %v", err)
		log.Printf("   Клиенты не найдут сервер автоматически — укажите адрес вручную в настройках клиента")
		return
	}
	s.mdnsServer = mdnsServer
	log.Printf("📡 mDNS service started")
}

func (s *Server) Start() error {
	go s.hub.Run()
	go s.cleanupLoop()
	if s.config.DeadMan.Enabled {
		go s.deadManSwitchLoop()
	} else {
		log.Printf("💀 Dead Man's Switch: disabled")
	}
	if s.keyPath != "" {
		go s.usbWatchLoop()
	}
	s.startMDNS()

	addr := fmt.Sprintf("%s:%d", s.config.Server.Host, s.config.Server.Port)
	server := &http.Server{
		Addr:              addr,
		Handler:           s.routes(),
		ReadTimeout:       time.Duration(s.config.Timeouts.ReadSeconds) * time.Second,
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      time.Duration(s.config.Timeouts.WriteSeconds) * time.Second,
		IdleTimeout:       time.Duration(s.config.Timeouts.IdleSeconds) * time.Second,
		MaxHeaderBytes:    64 << 10,
	}

	log.Printf("🚀 HomeLAN Server %s starting on %s", Version, addr)
	log.Printf("👥 Max users: %d", s.config.Security.MaxUsers)
	log.Printf("📁 Files: %s (max file %d MB, quota %d MB)", s.storagePath, s.config.Files.MaxFileSizeMB, s.config.Files.MaxSizeMB)
	return server.ListenAndServe()
}

// usbWatchLoop — проверка наличия USB-ключа с защитой от «дребезга».
// Проверяет наличие ключа, читая байт (обход кэша).
// Если ошибка -> делает 3 быстрых повтора. Если все 3 с ошибкой -> ПАНИКА.
func (s *Server) usbWatchLoop() {
	log.Printf("👀 Watching USB key at: %s", s.keyPath)

	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	const maxRetries = 3                     // Сколько раз перепроверить перед удалением
	const retryDelay = 50 * time.Millisecond // Пауза между проверками

	checkUSB := func() error {
		f, err := os.Open(s.keyPath)
		if err != nil {
			return err
		}
		defer f.Close()

		// Читаем 1 байт, чтобы заставить систему опросить USB-контроллер
		buf := make([]byte, 1)
		_, err = f.Read(buf)
		if err != nil && err != io.EOF {
			return err
		}
		return nil
	}

	for range ticker.C {
		if err := checkUSB(); err != nil {
			log.Printf("⚠️ USB Check Warning: %v. Retrying...", err)

			confirmedMissing := true
			for i := 0; i < maxRetries; i++ {
				time.Sleep(retryDelay)
				if errRetry := checkUSB(); errRetry == nil {
					log.Printf("✅ USB recovered after glitch. False alarm cancelled.")
					confirmedMissing = false
					break
				}
			}

			if confirmedMissing {
				log.Printf("🚨 USB GONE CONFIRMED after %d retries. TRIGGERING PANIC.", maxRetries)
				s.panicHandler.Trigger("USB_KEY_GONE_CONFIRMED")
				return
			}
		}
	}
}

func (s *Server) cleanupLoop() {
	ticker := time.NewTicker(1 * time.Hour)
	defer ticker.Stop()
	for range ticker.C {
		s.runCleanup()
	}
}

// runCleanup удаляет истёкшие сообщения, файлы, сессии и брошенные частичные загрузки
func (s *Server) runCleanup() {
	deleted, err := s.db.DeleteExpiredMessages()
	if err != nil {
		log.Printf("Error cleaning expired messages: %v", err)
	} else if deleted > 0 {
		log.Printf("🧹 Cleaned %d expired messages", deleted)
	}

	paths, err := s.db.DeleteExpiredFiles()
	if err != nil {
		log.Printf("Error cleaning expired files: %v", err)
	} else {
		for _, path := range paths {
			if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
				log.Printf("Error removing file %s: %v", path, err)
			}
		}
		if len(paths) > 0 {
			log.Printf("🧹 Cleaned %d expired files", len(paths))
		}
	}

	pruned, err := s.db.PruneSessions(sessionPruneAge)
	if err != nil {
		log.Printf("Error pruning sessions: %v", err)
	} else if pruned > 0 {
		log.Printf("🧹 Pruned %d stale sessions", pruned)
	}

	// Частичные загрузки (*.part), брошенные больше часа назад
	entries, err := os.ReadDir(s.storagePath)
	if err == nil {
		cutoff := time.Now().Add(-1 * time.Hour)
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".part") {
				continue
			}
			info, err := e.Info()
			if err == nil && info.ModTime().Before(cutoff) {
				os.Remove(filepath.Join(s.storagePath, e.Name()))
			}
		}
	}
}

// deadManSwitchLoop — автовайп при длительном отсутствии администратора.
//
// Учитывается активность по любому устройству админа (не только логин), а
// резкий скачок системного времени вперёд между проверками (например, ручная
// установка даты на Orange Pi без RTC) не приводит к ложному срабатыванию.
func (s *Server) deadManSwitchLoop() {
	const interval = 1 * time.Hour
	log.Printf("💀 Dead Man's Switch: %d days", s.config.DeadMan.TimeoutDays)

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	lastTick := time.Now()
	for range ticker.C {
		now := time.Now()
		jumped := now.Sub(lastTick) > 2*interval
		lastTick = now

		if now.Year() < 2024 {
			log.Printf("⚠️ Invalid system time, skipping dead man's switch check")
			continue
		}
		if jumped {
			log.Printf("⚠️ System clock jumped forward, skipping dead man's switch check this round")
			continue
		}

		if s.deadManShouldTrigger(now) {
			s.panicHandler.Trigger("DEAD_MAN_SWITCH")
		}
	}
}

// deadManShouldTrigger проверяет условие срабатывания (вынесено для тестов)
func (s *Server) deadManShouldTrigger(now time.Time) bool {
	admin, err := s.db.GetAdmin()
	if err != nil || admin == nil {
		return false
	}

	lastActivity, err := s.db.GetUserLastActivity(admin.ID)
	if err != nil || lastActivity == 0 {
		return false
	}

	daysSince := now.Sub(time.Unix(lastActivity, 0)).Hours() / 24
	if daysSince > float64(s.config.DeadMan.TimeoutDays) {
		log.Printf("💀 Dead Man's Switch triggered! Admin not seen for %.0f days", daysSince)
		return true
	}
	return false
}

func (s *Server) Close() error {
	if s.mdnsServer != nil {
		s.mdnsServer.Stop()
	}
	return s.db.Close()
}

func initUSB(explicitPath string) {
	log.Println("🔧 USB Master Key Setup")
	log.Println("")

	var target string
	if explicitPath != "" {
		if !usb.IsWritableDir(explicitPath) {
			log.Fatalf("❌ %s is not a writable directory", explicitPath)
		}
		target = explicitPath
	} else {
		drives := usb.ListAvailableUSB()
		switch len(drives) {
		case 0:
			log.Println("❌ No writable USB drives found!")
			log.Println("   Insert a USB drive and try again, or pass the mount point explicitly:")
			log.Println("   homelan-server --init-usb --usb /media/user/USB_KEY")
			os.Exit(1)
		case 1:
			target = drives[0]
		default:
			log.Println("Several candidate drives found:")
			for i, drive := range drives {
				log.Printf("  [%d] %s", i+1, drive)
			}
			log.Println("")
			log.Println("❌ Refusing to guess. Re-run with the exact mount point:")
			log.Printf("   homelan-server --init-usb --usb %s", drives[0])
			os.Exit(1)
		}
	}

	log.Printf("Creating key on: %s", target)

	masterKey, err := usb.GenerateKeyFile(target)
	if err != nil {
		log.Fatalf("❌ Failed to create key: %v", err)
	}

	log.Println("")
	log.Println("✅ Master key created successfully!")
	log.Printf("   Location: %s", masterKey.KeyPath)
	log.Println("")
	log.Println("⚠️  IMPORTANT:")
	log.Println("   1. Make a backup copy of this USB drive!")
	log.Println("   2. Store the backup in a safe place")
	log.Println("   3. Without this key, your data is UNRECOVERABLE")
	log.Println("")
	log.Println("You can now start the server normally.")
}

func main() {
	initUSBFlag := flag.Bool("init-usb", false, "create a new USB master key and exit")
	usbPath := flag.String("usb", "", "mount point of the USB drive for --init-usb")
	configPath := flag.String("config", "config.yaml", "path to config file")
	flag.Parse()

	log.Println("=================================")
	log.Println("   HomeLAN Messenger Server")
	log.Printf("   Version %s", Version)
	log.Println("=================================")

	if *initUSBFlag {
		initUSB(*usbPath)
		return
	}

	log.Println("🔑 Looking for USB master key...")

	masterKey, err := usb.FindMasterKey()
	if err != nil {
		if errors.Is(err, usb.ErrNoUSBFound) {
			log.Println("❌ No USB drive with homelan.key found!")
			log.Println("")
			log.Println("First time setup? Insert a USB drive and run:")
			log.Println("  homelan-server --init-usb")
			log.Println("")
			log.Println("Available USB drives:")
			for _, drive := range usb.ListAvailableUSB() {
				log.Printf("  • %s", drive)
			}
			os.Exit(1)
		}
		log.Fatalf("❌ USB key error: %v", err)
	}

	log.Printf("✅ Master key loaded from: %s", masterKey.KeyPath)

	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("❌ Failed to load config: %v", err)
	}

	server, err := NewServer(cfg, masterKey.Key, masterKey.KeyPath)
	if err != nil {
		log.Fatalf("❌ Failed to create server: %v", err)
	}
	defer server.Close()

	log.Println("🔒 Database encrypted with SQLCipher")
	if cfg.Security.DuressPassword != "" {
		log.Println("🚨 Duress password: enabled")
	}

	go func() {
		sigchan := make(chan os.Signal, 1)
		signal.Notify(sigchan, syscall.SIGINT, syscall.SIGTERM)
		<-sigchan
		log.Println("🛑 Shutting down...")
		server.Close()
		os.Exit(0)
	}()

	if err := server.Start(); err != nil {
		log.Fatalf("❌ Server error: %v", err)
	}
}
