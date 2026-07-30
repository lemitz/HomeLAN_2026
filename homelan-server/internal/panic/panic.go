package panic

import (
	"crypto/rand"
	"log"
	"os"
	"path/filepath"
	"syscall"
)

// Closer интерфейс нужен, чтобы принять и *sql.DB, и твою обертку *db.Database
type Closer interface {
	Close() error
}

type PanicHandler struct {
	dbConn     Closer
	dbPath     string
	filesPath  string
	onComplete func()
}

// New теперь принимает dbConn (интерфейс с методом Close)
func New(dbConn Closer, dbPath, filesPath string, onComplete func()) *PanicHandler {
	return &PanicHandler{
		dbConn:     dbConn,
		dbPath:     dbPath,
		filesPath:  filesPath,
		onComplete: onComplete,
	}
}

// Trigger запускает экстренное уничтожение данных
func (p *PanicHandler) Trigger(reason string) {
	log.Printf("🚨 PANIC TRIGGERED: %s", reason)

	// 0. ВАЖНО: Закрываем соединение с БД
	// Это снимает файловые блокировки и позволяет корректно удалить WAL
	if p.dbConn != nil {
		if err := p.dbConn.Close(); err != nil {
			log.Printf("⚠️ Error closing DB: %v", err)
		} else {
			log.Println("🔒 Database connection closed")
		}
	}

	// 1. Удаляем WAL и SHM (там могут быть незашифрованные данные)
	os.Remove(p.dbPath + "-wal")
	os.Remove(p.dbPath + "-shm")
	log.Println("🗑️ WAL/SHM removed")

	// 2. Перезаписываем заголовок БД (первые 4KB = SQLCipher header)
	if err := p.overwriteFileHeader(p.dbPath, 4096); err != nil {
		log.Printf("⚠️ Failed to overwrite DB header: %v", err)
	} else {
		log.Println("🗑️ Database header destroyed")
	}

	// 3. Удаляем все файлы
	if err := p.secureDeleteDir(p.filesPath); err != nil {
		log.Printf("⚠️ Failed to delete files: %v", err)
	} else {
		log.Println("🗑️ Files destroyed")
	}

	// 4. Удаляем саму БД
	os.Remove(p.dbPath)
	log.Println("🗑️ Database removed")

	// 5. ВАЖНО: Сбрасываем буферы файловой системы на диск (для SD-карты)
	syscall.Sync()
	log.Println("💾 Filesystem synced (buffers flushed)")

	log.Println("🚨 PANIC WIPE COMPLETE")

	// 6. Вызываем callback (обычно os.Exit)
	if p.onComplete != nil {
		p.onComplete()
	}
}

// overwriteFileHeader перезаписывает начало файла случайными данными
func (p *PanicHandler) overwriteFileHeader(path string, size int) error {
	f, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	defer f.Close()

	garbage := make([]byte, size)
	rand.Read(garbage)

	_, err = f.Write(garbage)
	if err != nil {
		return err
	}

	// Принудительно пишем изменения этого конкретного файла на диск
	return f.Sync()
}

// secureDeleteDir удаляет директорию с перезаписью файлов
func (p *PanicHandler) secureDeleteDir(dir string) error {
	return filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil // игнорируем ошибки, продолжаем
		}

		if !info.IsDir() {
			// Перезаписываем первые 4KB каждого файла
			p.overwriteFileHeader(path, 4096)
			os.Remove(path)
		}

		return nil
	})
}