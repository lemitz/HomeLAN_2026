package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
	"homelan-server/internal/config"
	"homelan-server/internal/db"
	"homelan-server/internal/linking"
	"homelan-server/internal/mdns"
	"homelan-server/internal/panic"
	"homelan-server/internal/usb"
	"homelan-server/internal/utils"
	"homelan-server/internal/ws"
)

const (
	maxFileSize = 100 << 20 // 100MB
	uploadPath  = "./data/files"
)

type Server struct {
	config         *config.Config
	db             *db.Database
	hub            *ws.Hub
	upgrader       websocket.Upgrader
	masterKey      []byte
	keyPath        string
	panicHandler   *panic.PanicHandler
	linkingService *linking.LinkingService
	mdnsServer     *mdns.MDNSServer
}

func NewServer(cfg *config.Config, masterKey []byte, keyPath string) (*Server, error) {
	database, err := db.New(cfg.Database.Path, masterKey)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to database: %w", err)
	}

	hub := ws.NewHub(database)

	panicHandler := panic.New(
		database,
		cfg.Database.Path,
		cfg.Files.StoragePath,
		func() { os.Exit(1) },
	)

	linkingService := linking.NewLinkingService()

	mdnsServer, err := mdns.New(cfg.Server.Port)
	if err != nil {
		log.Printf("⚠️ mDNS failed to start: %v", err)
	} else {
		log.Printf("📡 mDNS service started")
	}

	return &Server{
		config:         cfg,
		db:             database,
		hub:            hub,
		masterKey:      masterKey,
		keyPath:        keyPath,
		panicHandler:   panicHandler,
		linkingService: linkingService,
		mdnsServer:     mdnsServer,
		upgrader: websocket.Upgrader{
			ReadBufferSize:  1024,
			WriteBufferSize: 1024,
			CheckOrigin: func(r *http.Request) bool {
				return true
			},
		},
	}, nil
}

func (s *Server) Start() error {
	go s.hub.Run()
	go s.cleanupLoop()
	go s.deadManSwitchLoop()
	go s.usbWatchLoop()

	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/api/register", s.handleRegister)
	mux.HandleFunc("/api/login", s.handleLogin)
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

	addr := fmt.Sprintf("%s:%d", s.config.Server.Host, s.config.Server.Port)
	server := &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  time.Duration(s.config.Timeouts.ReadSeconds) * time.Second,
		WriteTimeout: time.Duration(s.config.Timeouts.WriteSeconds) * time.Second,
		IdleTimeout:  time.Duration(s.config.Timeouts.IdleSeconds) * time.Second,
	}

	log.Printf("🚀 HomeLAN Server starting on %s", addr)
	log.Printf("👥 Max users: %d", s.config.Security.MaxUsers)
	return server.ListenAndServe()
}

// usbWatchLoop - БЕЗОПАСНАЯ ВЕРСИЯ С ЗАЩИТОЙ ОТ "ДРЕБЕЗГА"
// Проверяет наличие ключа, читая байт (обход кэша).
// Если ошибка -> делает 3 быстрых повтора. Если все 3 с ошибкой -> ПАНИКА.
func (s *Server) usbWatchLoop() {
	log.Printf("👀 Watching USB key at: %s", s.keyPath)

	// Проверяем каждую секунду
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	// Настройки безопасности (защита от случайного сбоя питания)
	const maxRetries = 3                     // Сколько раз перепроверить перед удалением
	const retryDelay = 50 * time.Millisecond // Пауза между проверками (очень быстро)

	for range ticker.C {
		// Внутренняя функция для проверки (возвращает ошибку, если флешки нет)
		checkUSB := func() error {
			f, err := os.Open(s.keyPath)
			if err != nil {
				return err // Ошибка открытия
			}
			defer f.Close()

			// Читаем 1 байт, чтобы заставить систему опросить USB-контроллер
			buf := make([]byte, 1)
			_, err = f.Read(buf)
			if err != nil && err != io.EOF {
				return err // Ошибка ввода-вывода (I/O error)
			}
			return nil // Всё ок
		}

		// Первая попытка
		if err := checkUSB(); err != nil {
			log.Printf("⚠️ USB Check Warning: %v. Retrying...", err)

			confirmedMissing := true
			// Начинаем цикл перепроверки
			for i := 0; i < maxRetries; i++ {
				time.Sleep(retryDelay) // Ждем чуть-чуть
				if errRetry := checkUSB(); errRetry == nil {
					// Флешка "вернулась" (значит это был глюк питания или драйвера)
					log.Printf("✅ USB recovered after glitch. False alarm cancelled.")
					confirmedMissing = false
					break
				}
			}

			// Если после всех попыток она всё ещё не читается — ВЗРЫВАЕМ
			if confirmedMissing {
				log.Printf("🚨 USB GONE CONFIRMED after %d retries. TRIGGERING PANIC.", maxRetries)
				s.panicHandler.Trigger("USB_KEY_GONE_CONFIRMED")
				return
			}
		}
	}
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":      "ok",
		"server_time": time.Now().Unix(),
	})
}

func (s *Server) handleTime(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"server_time": time.Now().Unix(),
	})
}

func (s *Server) handlePanic(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Confirm string `json:"confirm"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	if req.Confirm != "DESTROY_ALL_DATA" {
		http.Error(w, "Invalid confirmation", http.StatusBadRequest)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status": "panic_initiated",
	})

	go func() {
		time.Sleep(500 * time.Millisecond)
		s.panicHandler.Trigger("MANUAL_PANIC_API")
	}()
}

func (s *Server) handleGetUser(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	userIDStr := filepath.Base(r.URL.Path)
	userID, err := strconv.ParseInt(userIDStr, 10, 64)
	if err != nil {
		http.Error(w, "Invalid user ID", http.StatusBadRequest)
		return
	}

	user, err := s.db.GetUserByID(userID)
	if err != nil {
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}
	if user == nil {
		http.Error(w, "User not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"id":         user.ID,
		"username":   user.Username,
		"public_key": user.PublicKey,
		"is_admin":   user.IsAdmin,
	})
}

func (s *Server) handleGetPartner(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	userIDStr := r.URL.Query().Get("user_id")
	if userIDStr == "" {
		http.Error(w, "Missing user_id", http.StatusBadRequest)
		return
	}

	userID, err := strconv.ParseInt(userIDStr, 10, 64)
	if err != nil {
		http.Error(w, "Invalid user_id", http.StatusBadRequest)
		return
	}

	partner, err := s.db.GetPartner(userID)
	if err != nil {
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}
	if partner == nil {
		http.Error(w, "No partner found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"id":          partner.ID,
		"username":    partner.Username,
		"public_key":  partner.PublicKey,
		"server_time": time.Now().Unix(),
	})
}

func (s *Server) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	userID := r.URL.Query().Get("user_id")
	deviceID := r.URL.Query().Get("device_id")
	token := r.URL.Query().Get("token")

	if userID == "" || deviceID == "" || token == "" {
		http.Error(w, "Missing parameters", http.StatusBadRequest)
		return
	}

	device, err := s.db.GetDeviceByID(deviceID)
	if err != nil || device == nil {
		http.Error(w, "Device not found", http.StatusUnauthorized)
		return
	}
	if device.IsRevoked {
		http.Error(w, "Device revoked", http.StatusForbidden)
		return
	}

	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade error: %v", err)
		return
	}

	client := s.hub.RegisterClient(conn, device.UserID, deviceID)
	s.db.UpdateDeviceLastSeen(deviceID)
	s.db.UpdateUserLastSeen(device.UserID)

	go client.WritePump()
	go client.ReadPump()
}

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Username   string `json:"username"`
		Password   string `json:"password"`
		DeviceID   string `json:"device_id"`
		DeviceName string `json:"device_name"`
		DeviceType string `json:"device_type"`
		PublicKey  []byte `json:"public_key"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	if req.Username == "" || req.Password == "" || req.DeviceID == "" {
		http.Error(w, "Missing required fields", http.StatusBadRequest)
		return
	}

	userCount, err := s.db.GetUserCount()
	if err != nil {
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}
	if userCount >= s.config.Security.MaxUsers {
		http.Error(w, "Maximum users reached", http.StatusForbidden)
		return
	}

	existing, err := s.db.GetUserByUsername(req.Username)
	if err != nil {
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}
	if existing != nil {
		http.Error(w, "Username already exists", http.StatusConflict)
		return
	}

	admin, _ := s.db.GetAdmin()
	isAdmin := admin == nil

	user, err := s.db.CreateUser(req.Username, req.Password, isAdmin)
	if err != nil {
		http.Error(w, "Failed to create user", http.StatusInternalServerError)
		return
	}

	if len(req.PublicKey) > 0 {
		s.db.UpdateUserPublicKey(user.ID, req.PublicKey)
	}

	device, err := s.db.CreateDevice(user.ID, req.DeviceID, req.DeviceName, req.DeviceType, req.PublicKey)
	if err != nil {
		http.Error(w, "Failed to create device", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success":     true,
		"user_id":     user.ID,
		"device_id":   device.DeviceID,
		"is_admin":    isAdmin,
		"server_time": time.Now().Unix(),
	})

	log.Printf("✅ User registered: %s (admin: %v) [%d/%d]", req.Username, isAdmin, userCount+1, s.config.Security.MaxUsers)
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Username  string `json:"username"`
		Password  string `json:"password"`
		DeviceID  string `json:"device_id"`
		PublicKey []byte `json:"public_key"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	user, err := s.db.GetUserByUsername(req.Username)
	if err != nil {
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}
	if user == nil {
		http.Error(w, "Invalid credentials", http.StatusUnauthorized)
		return
	}

	if s.config.Security.DuressPassword != "" && req.Password == s.config.Security.DuressPassword {
		log.Printf("🚨 DURESS PASSWORD ENTERED! Triggering emergency wipe")
		go func() {
			time.Sleep(500 * time.Millisecond)
			s.triggerPanic()
		}()
		http.Error(w, "Invalid credentials", http.StatusUnauthorized)
		return
	}

	if user.PasswordHash != req.Password {
		http.Error(w, "Invalid credentials", http.StatusUnauthorized)
		return
	}

	device, err := s.db.GetDeviceByID(req.DeviceID)
	if err != nil {
		http.Error(w, "Internal error", http.StatusInternalServerError)
		return
	}
	if device == nil {
		http.Error(w, "Device not registered", http.StatusUnauthorized)
		return
	}
	if device.IsRevoked {
		http.Error(w, "Device revoked", http.StatusForbidden)
		return
	}

	if len(req.PublicKey) > 0 {
		s.db.UpdateUserPublicKey(user.ID, req.PublicKey)
	}

	s.db.UpdateUserLastSeen(user.ID)
	s.db.UpdateDeviceLastSeen(req.DeviceID)

	partner, _ := s.db.GetPartner(user.ID)
	var partnerID int64 = 0
	var partnerUsername string = ""
	if partner != nil {
		partnerID = partner.ID
		partnerUsername = partner.Username
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success":          true,
		"user_id":          user.ID,
		"is_admin":         user.IsAdmin,
		"partner_id":       partnerID,
		"partner_username": partnerUsername,
		"server_time":      time.Now().Unix(),
	})

	log.Printf("✅ User logged in: %s", req.Username)
}

func generateFileID() string {
	bytes := make([]byte, 16)
	rand.Read(bytes)
	return hex.EncodeToString(bytes)
}

func (s *Server) handleFileUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxFileSize)

	// Ограничиваем буфер в RAM 32MB, остальное — во временные файлы на диске
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		log.Printf("ParseMultipartForm error: %v", err)
		http.Error(w, "File too large or invalid form", http.StatusBadRequest)
		return
	}

	userIDStr := r.FormValue("user_id")
	if userIDStr == "" {
		http.Error(w, "Missing user_id", http.StatusBadRequest)
		return
	}
	userID, err := strconv.ParseInt(userIDStr, 10, 64)
	if err != nil {
		http.Error(w, "Invalid user_id", http.StatusBadRequest)
		return
	}

	user, err := s.db.GetUserByID(userID)
	if err != nil || user == nil {
		http.Error(w, "User not found", http.StatusUnauthorized)
		return
	}

	fileName := r.FormValue("file_name")
	mimeType := r.FormValue("mime_type")
	if mimeType == "" {
		mimeType = "application/octet-stream"
	}

	file, _, err := r.FormFile("file")
	if err != nil {
		log.Printf("FormFile error: %v", err)
		http.Error(w, "No file uploaded", http.StatusBadRequest)
		return
	}
	defer file.Close()

	if !utils.HasEnoughSpace(uploadPath, maxFileSize) {
		http.Error(w, "Insufficient disk space", http.StatusInsufficientStorage)
		return
	}

	if err := os.MkdirAll(uploadPath, 0700); err != nil {
		http.Error(w, "Storage error", http.StatusInternalServerError)
		return
	}

	fileID := generateFileID()
	filePath := filepath.Join(uploadPath, fileID)

	dst, err := os.Create(filePath)
	if err != nil {
		log.Printf("Create file error: %v", err)
		http.Error(w, "Failed to create file", http.StatusInternalServerError)
		return
	}
	defer dst.Close()

	written, err := io.Copy(dst, io.LimitReader(file, maxFileSize))
	if err != nil {
		os.Remove(filePath)
		log.Printf("Copy error: %v", err)
		http.Error(w, "Upload failed", http.StatusInternalServerError)
		return
	}

	err = s.db.CreateFile(fileID, userID, []byte(fileName), written, mimeType, filePath)
	if err != nil {
		os.Remove(filePath)
		log.Printf("DB error: %v", err)
		http.Error(w, "Database error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success": true,
		"file_id": fileID,
		"size":    written,
	})

	log.Printf("📁 File uploaded: %s (%d bytes) by user %d", fileID, written, userID)
}

func (s *Server) handleFiles(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/api/files/")
	parts := strings.Split(path, "/")

	if len(parts) == 0 || parts[0] == "" {
		http.Error(w, "File ID required", http.StatusBadRequest)
		return
	}

	fileID := parts[0]

	if len(parts) == 2 && parts[1] == "info" {
		s.handleFileInfo(w, r, fileID)
		return
	}

	s.handleFileDownload(w, r, fileID)
}

func (s *Server) handleFileInfo(w http.ResponseWriter, r *http.Request, fileID string) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	file, err := s.db.GetFileByID(fileID)
	if err != nil || file == nil {
		http.Error(w, "File not found", http.StatusNotFound)
		return
	}

	if file.IsDeleted {
		http.Error(w, "File deleted", http.StatusGone)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"file_id":    file.ID,
		"file_name":  string(file.FileNameEncrypted),
		"file_size":  file.FileSize,
		"mime_type":  file.MimeType,
		"created_at": file.CreatedAt,
	})
}

func (s *Server) handleFileDownload(w http.ResponseWriter, r *http.Request, fileID string) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	file, err := s.db.GetFileByID(fileID)
	if err != nil || file == nil {
		http.Error(w, "File not found", http.StatusNotFound)
		return
	}

	if file.IsDeleted {
		http.Error(w, "File deleted", http.StatusGone)
		return
	}

	f, err := os.Open(file.StoragePath)
	if err != nil {
		http.Error(w, "File not found", http.StatusNotFound)
		return
	}
	defer f.Close()

	stat, err := f.Stat()
	if err != nil {
		http.Error(w, "File error", http.StatusInternalServerError)
		return
	}

	fileSize := stat.Size()

	w.Header().Set("Content-Type", file.MimeType)
	w.Header().Set("Accept-Ranges", "bytes")

	rangeHeader := r.Header.Get("Range")
	if rangeHeader != "" {
		var start, end int64
		n, _ := fmt.Sscanf(rangeHeader, "bytes=%d-%d", &start, &end)
		if n == 1 {
			end = fileSize - 1
		}

		if start >= fileSize || end >= fileSize || start > end {
			http.Error(w, "Invalid range", http.StatusRequestedRangeNotSatisfiable)
			return
		}

		f.Seek(start, 0)
		length := end - start + 1

		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, fileSize))
		w.Header().Set("Content-Length", strconv.FormatInt(length, 10))
		w.WriteHeader(http.StatusPartialContent)

		io.CopyN(w, f, length)
	} else {
		w.Header().Set("Content-Length", strconv.FormatInt(fileSize, 10))
		io.Copy(w, f)
	}

	log.Printf("📥 File downloaded: %s", fileID)
}

func (s *Server) handleLinkCreate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		UserID int64 `json:"user_id"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	if req.UserID == 0 {
		http.Error(w, "Missing user_id", http.StatusBadRequest)
		return
	}

	user, err := s.db.GetUserByID(req.UserID)
	if err != nil || user == nil {
		http.Error(w, "User not found", http.StatusNotFound)
		return
	}

	link := s.linkingService.CreateLink(req.UserID)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success":     true,
		"link_code":   link.Code,
		"expires_at":  link.ExpiresAt.Unix(),
		"server_time": time.Now().Unix(),
	})

	log.Printf("🔗 Link code created for user %d: %s", req.UserID, link.Code)
}

func (s *Server) handleLinkComplete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		LinkCode   string `json:"link_code"`
		DeviceID   string `json:"device_id"`
		DeviceName string `json:"device_name"`
		DeviceType string `json:"device_type"`
		PublicKey  []byte `json:"public_key"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	if req.LinkCode == "" {
		http.Error(w, "Missing link_code", http.StatusBadRequest)
		return
	}

	link := s.linkingService.GetLink(req.LinkCode)
	if link == nil {
		http.Error(w, "Invalid or expired link code", http.StatusBadRequest)
		return
	}

	existingDevice, _ := s.db.GetDeviceByID(req.DeviceID)
	if existingDevice != nil {
		http.Error(w, "Device already registered", http.StatusConflict)
		return
	}

	device, err := s.db.CreateDevice(
		link.UserID,
		req.DeviceID,
		req.DeviceName,
		req.DeviceType,
		req.PublicKey,
	)
	if err != nil {
		http.Error(w, "Failed to create device", http.StatusInternalServerError)
		return
	}

	user, _ := s.db.GetUserByID(link.UserID)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success":     true,
		"user_id":     link.UserID,
		"username":    user.Username,
		"device_id":   device.DeviceID,
		"public_key":  user.PublicKey,
		"server_time": time.Now().Unix(),
	})

	log.Printf("🔗 Device linked: %s to user %d (%s)", device.DeviceID, link.UserID, user.Username)
}

func (s *Server) handleDevicesList(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	userIDStr := r.URL.Query().Get("user_id")
	if userIDStr == "" {
		http.Error(w, "Missing user_id", http.StatusBadRequest)
		return
	}

	userID, err := strconv.ParseInt(userIDStr, 10, 64)
	if err != nil {
		http.Error(w, "Invalid user_id", http.StatusBadRequest)
		return
	}

	devices, err := s.db.GetUserDevices(userID)
	if err != nil {
		http.Error(w, "Database error", http.StatusInternalServerError)
		return
	}

	deviceList := make([]map[string]interface{}, 0, len(devices))
	for _, d := range devices {
		deviceList = append(deviceList, map[string]interface{}{
			"device_id":   d.DeviceID,
			"device_name": d.DeviceName,
			"device_type": d.DeviceType,
			"created_at":  d.CreatedAt,
			"last_seen":   d.LastSeen,
			"is_online":   s.hub.IsDeviceOnline(d.DeviceID),
		})
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success":     true,
		"devices":     deviceList,
		"server_time": time.Now().Unix(),
	})
}

func (s *Server) handleDeviceRevoke(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		UserID   int64  `json:"user_id"`
		DeviceID string `json:"device_id"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	device, err := s.db.GetDeviceByID(req.DeviceID)
	if err != nil || device == nil {
		http.Error(w, "Device not found", http.StatusNotFound)
		return
	}

	if device.UserID != req.UserID {
		http.Error(w, "Device does not belong to user", http.StatusForbidden)
		return
	}

	if err := s.db.RevokeDevice(req.DeviceID); err != nil {
		http.Error(w, "Failed to revoke device", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success":     true,
		"server_time": time.Now().Unix(),
	})

	log.Printf("🚫 Device revoked: %s by user %d", req.DeviceID, req.UserID)
}

func (s *Server) cleanupLoop() {
	ticker := time.NewTicker(1 * time.Hour)
	for range ticker.C {
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
				if err := os.Remove(path); err != nil {
					log.Printf("Error removing file %s: %v", path, err)
				}
			}
			if len(paths) > 0 {
				log.Printf("🧹 Cleaned %d expired files", len(paths))
			}
		}
	}
}

func (s *Server) deadManSwitchLoop() {
	ticker := time.NewTicker(1 * time.Hour)
	for range ticker.C {
		if time.Now().Year() < 2024 {
			log.Printf("⚠️ Invalid system time, skipping dead man's switch check")
			continue
		}

		admin, err := s.db.GetAdmin()
		if err != nil || admin == nil {
			continue
		}

		daysSinceLastSeen := time.Since(time.Unix(admin.LastSeen, 0)).Hours() / 24
		if daysSinceLastSeen > float64(s.config.DeadMan.TimeoutDays) {
			log.Printf("💀 Dead Man's Switch triggered! Admin not seen for %.0f days", daysSinceLastSeen)
			s.triggerPanic()
		}
	}
}

func (s *Server) triggerPanic() {
	s.panicHandler.Trigger("DEAD_MAN_SWITCH")
}

func (s *Server) Close() error {
	if s.mdnsServer != nil {
		s.mdnsServer.Stop()
	}
	return s.db.Close()
}

func init() {
	if len(os.Args) > 1 && os.Args[1] == "--init-usb" {
		initUSB()
		os.Exit(0)
	}
}

func initUSB() {
	log.Println("🔧 USB Master Key Setup")
	log.Println("")

	drives := usb.ListAvailableUSB()
	if len(drives) == 0 {
		log.Println("❌ No writable USB drives found!")
		log.Println("   Insert a USB drive and try again.")
		return
	}

	log.Println("Available USB drives:")
	for i, drive := range drives {
		log.Printf("  [%d] %s", i+1, drive)
	}
	log.Println("")

	selectedDrive := drives[0]
	log.Printf("Creating key on: %s", selectedDrive)

	masterKey, err := usb.GenerateKeyFile(selectedDrive)
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
	log.Println("=================================")
	log.Println("   HomeLAN Messenger Server")
	log.Println("   Version 1.0.0")
	log.Println("=================================")

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

	cfg, err := config.Load("config.yaml")
	if err != nil {
		log.Fatalf("❌ Failed to load config: %v", err)
	}

	server, err := NewServer(cfg, masterKey.Key, masterKey.KeyPath)
	if err != nil {
		log.Fatalf("❌ Failed to create server: %v", err)
	}
	defer server.Close()

	log.Println("🔒 Database encrypted with SQLCipher")

	if cfg.DeadMan.Enabled {
		log.Printf("💀 Dead Man's Switch: %d days", cfg.DeadMan.TimeoutDays)
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