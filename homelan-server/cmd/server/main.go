package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"homelan-server/internal/config"
	"homelan-server/internal/db"
	"homelan-server/internal/mdns"
	"homelan-server/internal/panic"
	"homelan-server/internal/server"
	"homelan-server/internal/usb"
)

// Version — версия сервера (переопределяется при сборке через -ldflags).
var Version = "1.0.0-dev"

func main() {
	initUSB := flag.Bool("init-usb", false, "создать USB master key на съёмном накопителе")
	drive := flag.String("drive", "", "накопитель для --init-usb (по умолчанию — спросить)")
	force := flag.Bool("force", false, "перезаписать существующий ключ (данные БД станут недоступны!)")
	configPath := flag.String("config", "config.yaml", "путь к конфигу")
	keyFile := flag.String("key-file", "", "ТОЛЬКО ДЛЯ РАЗРАБОТКИ: путь к homelan.key вместо поиска на USB")
	flag.Parse()

	log.Printf("HomeLAN Messenger Server %s", Version)

	if *initUSB {
		if err := runInitUSB(*drive, *force); err != nil {
			log.Fatalf("❌ %v", err)
		}
		return
	}

	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("❌ Failed to load config: %v", err)
	}

	var masterKey *usb.MasterKey
	if *keyFile != "" {
		log.Printf("⚠️ DEVELOPMENT MODE: using key file %s instead of a USB drive", *keyFile)
		masterKey, err = usb.LoadKeyFile(*keyFile)
	} else {
		log.Println("🔑 Looking for USB master key...")
		masterKey, err = usb.FindMasterKey()
	}
	if err != nil {
		if errors.Is(err, usb.ErrNoUSBFound) {
			log.Println("❌ No USB drive with homelan.key found!")
			log.Println("First time setup? Insert a USB drive and run: homelan-server --init-usb")
			for _, d := range usb.ListAvailableUSB() {
				log.Printf("  • available: %s", d)
			}
			os.Exit(1)
		}
		log.Fatalf("❌ USB key error: %v", err)
	}
	log.Printf("✅ Master key loaded from: %s", masterKey.KeyPath)

	database, err := db.New(cfg.Database.Path, masterKey.Key)
	if err != nil {
		log.Fatalf("❌ Failed to open database: %v", err)
	}
	log.Println("🔒 Database encrypted with SQLCipher")

	panicHandler := panic.New(database, cfg.Database.Path, cfg.Files.StoragePath, masterKey.KeyPath,
		func() { os.Exit(1) })
	srv := server.New(cfg, database, panicHandler)

	mdnsServer, err := mdns.New(cfg.Server.Port, Version)
	if err != nil {
		log.Printf("⚠️ mDNS failed to start: %v", err)
	}

	go srv.WatchUSB(masterKey.KeyPath)

	if cfg.DeadMan.Enabled {
		log.Printf("💀 Dead Man's Switch: %d days", cfg.DeadMan.TimeoutDays)
	} else {
		log.Printf("💀 Dead Man's Switch: disabled")
	}
	if cfg.Security.DuressPassword != "" {
		log.Printf("🚨 Duress password: enabled")
	}

	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		<-sig
		log.Println("🛑 Shutting down...")
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		srv.Shutdown(ctx)
	}()

	if err := srv.Start(); err != nil {
		log.Printf("❌ Server error: %v", err)
	}
	if mdnsServer != nil {
		mdnsServer.Stop()
	}
	database.Close()
	log.Println("👋 Stopped")
}

func runInitUSB(drive string, force bool) error {
	log.Println("🔧 USB Master Key Setup")
	drives := usb.ListAvailableUSB()
	if drive == "" {
		if len(drives) == 0 {
			return errors.New("no writable USB drives found — insert a USB drive and try again")
		}
		fmt.Println("Available USB drives:")
		for i, d := range drives {
			fmt.Printf("  [%d] %s\n", i+1, d)
		}
		fmt.Print("Select drive number: ")
		var n int
		if _, err := fmt.Scanln(&n); err != nil || n < 1 || n > len(drives) {
			return errors.New("invalid selection")
		}
		drive = drives[n-1]
	}

	key, err := usb.GenerateKeyFile(drive, force)
	if errors.Is(err, usb.ErrKeyExists) {
		return fmt.Errorf("%s already has homelan.key. Overwriting it makes the existing database "+
			"UNRECOVERABLE. Use --force only if you really want a new empty server", drive)
	}
	if err != nil {
		return err
	}
	log.Printf("✅ Master key created: %s", key.KeyPath)
	log.Println("⚠️  Make a backup copy of this key and keep it in a safe place.")
	log.Println("⚠️  Without it the database cannot be decrypted.")
	return nil
}
