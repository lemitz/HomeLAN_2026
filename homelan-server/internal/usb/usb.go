package usb

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec" // Добавлено
	"path/filepath"
	"runtime"
	"strings"
)

const (
	KeyFileName = "homelan.key"
	KeySize     = 32 // 256 bit
)

var (
	ErrNoUSBFound = errors.New("USB drive with homelan.key not found")
	ErrInvalidKey = errors.New("invalid key format in homelan.key")
)

// MasterKey хранит ключ и путь к USB
type MasterKey struct {
	Key     []byte
	KeyPath string
	USBPath string
}

// FindMasterKey ищет флешку с ключом
func FindMasterKey() (*MasterKey, error) {
	drives := getMountedDrives()

	for _, drive := range drives {
		keyPath := filepath.Join(drive, KeyFileName)

		if _, err := os.Stat(keyPath); err == nil {
			keyHex, err := os.ReadFile(keyPath)
			if err != nil {
				continue
			}

			keyHex = []byte(strings.TrimSpace(string(keyHex)))
			key, err := hex.DecodeString(string(keyHex))
			if err != nil {
				return nil, fmt.Errorf("%w: invalid hex encoding", ErrInvalidKey)
			}

			if len(key) != KeySize {
				return nil, fmt.Errorf("%w: expected %d bytes, got %d", ErrInvalidKey, KeySize, len(key))
			}

			return &MasterKey{
				Key:     key,
				KeyPath: keyPath,
				USBPath: drive,
			}, nil
		}
	}

	return nil, ErrNoUSBFound
}

// GenerateKeyFile создаёт новый ключ на указанном USB
func GenerateKeyFile(usbPath string) (*MasterKey, error) {
	key := make([]byte, KeySize)
	if _, err := rand.Read(key); err != nil {
		return nil, fmt.Errorf("failed to generate random key: %w", err)
	}

	keyPath := filepath.Join(usbPath, KeyFileName)
	keyHex := hex.EncodeToString(key)

	if err := os.WriteFile(keyPath, []byte(keyHex+"\n"), 0600); err != nil {
		return nil, fmt.Errorf("failed to write key file: %w", err)
	}

	return &MasterKey{
		Key:     key,
		KeyPath: keyPath,
		USBPath: usbPath,
	}, nil
}

// ListAvailableUSB возвращает USB-накопители, куда можно записать ключ
func ListAvailableUSB() []string {
	var usable []string
	drives := getMountedDrives()

	for _, drive := range drives {
		testFile := filepath.Join(drive, ".homelan_write_test")
		if err := os.WriteFile(testFile, []byte("test"), 0600); err == nil {
			os.Remove(testFile)
			usable = append(usable, drive)
		}
	}

	return usable
}

func getMountedDrives() []string {
	if runtime.GOOS == "windows" {
		return getWindowsDrives()
	}
	return getLinuxDrives()
}

// getWindowsDrives использует PowerShell для поиска Removable дисков (Type 2)
func getWindowsDrives() []string {
	var drives []string

	// Используем PowerShell для получения только съёмных дисков
	cmd := exec.Command("powershell", "-Command",
		"Get-WmiObject Win32_LogicalDisk | Where-Object {$_.DriveType -eq 2} | Select-Object -ExpandProperty DeviceID")

	output, err := cmd.Output()
	if err != nil {
		// Fallback: ручная проверка (но это менее надёжно)
		return getWindowsDrivesFallback()
	}

	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if len(line) >= 2 && line[1] == ':' {
			drives = append(drives, line+"\\")
		}
	}

	return drives
}

// Fallback если PowerShell не сработал или недоступен
func getWindowsDrivesFallback() []string {
	var drives []string

	// Проверяем только типичные буквы для USB: E, F, G, H
	// Избегаем C, D (обычно системные/данные)
	for letter := 'E'; letter <= 'H'; letter++ {
		drive := fmt.Sprintf("%c:\\", letter)
		if info, err := os.Stat(drive); err == nil && info.IsDir() {
			drives = append(drives, drive)
		}
	}

	return drives
}

func getLinuxDrives() []string {
	var drives []string

	// Типичные точки монтирования USB в Linux
	mountPoints := []string{
		"/media",
		"/mnt",
		"/run/media",
	}

	for _, mp := range mountPoints {
		// Прямые поддиректории
		entries, err := os.ReadDir(mp)
		if err != nil {
			continue
		}

		for _, entry := range entries {
			if !entry.IsDir() {
				continue
			}

			subPath := filepath.Join(mp, entry.Name())

			// Для /media/username/USBNAME структуры
			subEntries, err := os.ReadDir(subPath)
			if err == nil {
				for _, subEntry := range subEntries {
					if subEntry.IsDir() {
						drives = append(drives, filepath.Join(subPath, subEntry.Name()))
					}
				}
			}

			drives = append(drives, subPath)
		}
	}

	return drives
}