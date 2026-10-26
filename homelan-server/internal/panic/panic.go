// Package panic — экстренное уничтожение данных сервера.
package panic

import (
	"crypto/rand"
	"io"
	"log"
	"os"
	"path/filepath"
	"sync"
)

// Closer — всё, что нужно закрыть перед удалением файлов БД.
type Closer interface {
	Close() error
}

// Reason — причина срабатывания.
type Reason string

const (
	ReasonUSBRemoved Reason = "USB_KEY_REMOVED"
	ReasonDuress     Reason = "DURESS_PASSWORD"
	ReasonDeadMan    Reason = "DEAD_MAN_SWITCH"
	ReasonManual     Reason = "MANUAL_PANIC_API"
)

type PanicHandler struct {
	dbConn     Closer
	dbPath     string
	filesPath  string
	keyPath    string
	onComplete func()
	once       sync.Once
}

// New создаёт обработчик. keyPath — путь к homelan.key на USB (может быть пустым).
func New(dbConn Closer, dbPath, filesPath, keyPath string, onComplete func()) *PanicHandler {
	return &PanicHandler{
		dbConn:     dbConn,
		dbPath:     dbPath,
		filesPath:  filesPath,
		keyPath:    keyPath,
		onComplete: onComplete,
	}
}

// Trigger запускает уничтожение данных. Повторные вызовы игнорируются.
//
// Порядок: закрыть БД → затереть ключ на USB (если флешка на месте и это
// не её извлечение) → затереть и удалить файл БД, WAL, SHM → удалить
// файлы пользователей → сбросить буферы ФС → onComplete (обычно os.Exit).
//
// Главная мера — уничтожение ключа: без него SQLCipher-БД нечитаема даже
// если на flash-памяти остались старые блоки (wear leveling).
func (p *PanicHandler) Trigger(reason Reason) {
	p.once.Do(func() { p.run(reason) })
}

func (p *PanicHandler) run(reason Reason) {
	log.Printf("🚨 PANIC TRIGGERED: %s", reason)

	if p.dbConn != nil {
		if err := p.dbConn.Close(); err != nil {
			log.Printf("⚠️ Error closing DB: %v", err)
		}
	}

	if reason != ReasonUSBRemoved && p.keyPath != "" {
		if err := shredFile(p.keyPath, -1); err != nil {
			log.Printf("⚠️ Failed to destroy USB key: %v", err)
		} else {
			log.Println("🗑️ USB master key destroyed")
		}
	}

	for _, path := range []string{p.dbPath + "-wal", p.dbPath + "-shm", p.dbPath} {
		if err := shredFile(path, -1); err != nil && !os.IsNotExist(err) {
			log.Printf("⚠️ Failed to destroy %s: %v", path, err)
		}
	}
	log.Println("🗑️ Database destroyed")

	if p.filesPath != "" {
		filepath.Walk(p.filesPath, func(path string, info os.FileInfo, err error) error {
			if err == nil && !info.IsDir() {
				// Файлы зашифрованы клиентами (E2E), ключи к ним лежали в БД —
				// достаточно затереть начало и удалить.
				shredFile(path, 4096)
			}
			return nil
		})
		log.Println("🗑️ Files destroyed")
	}

	syncFilesystem()
	log.Println("🚨 PANIC WIPE COMPLETE")

	if p.onComplete != nil {
		p.onComplete()
	}
}

// shredFile перезаписывает файл случайными байтами (limit < 0 — целиком)
// и удаляет его.
func shredFile(path string, limit int64) error {
	f, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		if os.IsNotExist(err) {
			return err
		}
		// Не смогли открыть на запись — хотя бы удалим.
		return os.Remove(path)
	}
	size := limit
	if info, statErr := f.Stat(); statErr == nil && (limit < 0 || info.Size() < limit) {
		size = info.Size()
	}
	if size > 0 {
		io.CopyN(f, rand.Reader, size)
		f.Sync()
	}
	f.Close()
	return os.Remove(path)
}
