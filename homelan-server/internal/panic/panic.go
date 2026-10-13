package panic

import (
	"crypto/rand"
	"io"
	"log"
	"os"
	"path/filepath"
	"sync"
)

const (
	// Размер блока при перезаписи файла случайными данными
	overwriteChunk = 1 << 20 // 1 MiB

	// Для вложений достаточно уничтожить начало файла: содержимое зашифровано
	// ключами клиентов, которых у сервера никогда не было.
	attachmentHeaderSize = 4096
)

// Closer интерфейс нужен, чтобы принять и *sql.DB, и обертку *db.Database
type Closer interface {
	Close() error
}

type PanicHandler struct {
	dbConn     Closer
	dbPath     string
	filesPath  string
	onComplete func()
	once       sync.Once
}

// New создаёт обработчик экстренного уничтожения данных
func New(dbConn Closer, dbPath, filesPath string, onComplete func()) *PanicHandler {
	return &PanicHandler{
		dbConn:     dbConn,
		dbPath:     dbPath,
		filesPath:  filesPath,
		onComplete: onComplete,
	}
}

// Trigger запускает экстренное уничтожение данных. Повторные вызовы (например,
// одновременно от USB-монитора и duress-пароля) игнорируются — вайп выполняется
// ровно один раз.
func (p *PanicHandler) Trigger(reason string) {
	p.once.Do(func() { p.run(reason) })
}

func (p *PanicHandler) run(reason string) {
	log.Printf("🚨 PANIC TRIGGERED: %s", reason)

	// 0. Закрываем соединение с БД: снимает файловые блокировки и даёт корректно удалить WAL
	if p.dbConn != nil {
		if err := p.dbConn.Close(); err != nil {
			log.Printf("⚠️ Error closing DB: %v", err)
		} else {
			log.Println("🔒 Database connection closed")
		}
	}

	// 1. WAL содержит последние страницы БД — затираем целиком, SHM (индекс) просто удаляем
	if err := overwriteFile(p.dbPath+"-wal", 0); err != nil && !os.IsNotExist(err) {
		log.Printf("⚠️ Failed to overwrite WAL: %v", err)
	}
	os.Remove(p.dbPath + "-wal")
	os.Remove(p.dbPath + "-shm")
	log.Println("🗑️ WAL/SHM removed")

	// 2. Перезаписываем БД ЦЕЛИКОМ. Сервер открывает SQLCipher raw-ключом (x'…'),
	//    при котором ключ шифрования не зависит от salt в заголовке, поэтому
	//    затирания одного заголовка недостаточно: обладатель USB-ключа смог бы
	//    прочитать остальные страницы. БД для 2 пользователей небольшая.
	if err := overwriteFile(p.dbPath, 0); err != nil {
		log.Printf("⚠️ Failed to overwrite DB: %v", err)
	} else {
		log.Println("🗑️ Database content destroyed")
	}

	// 3. Удаляем все файлы вложений
	if err := p.secureDeleteDir(p.filesPath); err != nil {
		log.Printf("⚠️ Failed to delete files: %v", err)
	} else {
		log.Println("🗑️ Files destroyed")
	}

	// 4. Удаляем саму БД
	os.Remove(p.dbPath)
	log.Println("🗑️ Database removed")

	// 5. Сбрасываем буферы файловой системы на диск (важно для SD-карты)
	syncFilesystem()
	log.Println("💾 Filesystem synced (buffers flushed)")

	log.Println("🚨 PANIC WIPE COMPLETE")

	// 6. Вызываем callback (обычно os.Exit)
	if p.onComplete != nil {
		p.onComplete()
	}
}

// overwriteFile перезаписывает файл случайными данными и делает fsync.
// limit > 0 ограничивает объём перезаписи первыми limit байтами; 0 — весь файл.
func overwriteFile(path string, limit int64) error {
	f, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		return err
	}

	remaining := info.Size()
	if limit > 0 && remaining > limit {
		remaining = limit
	}

	buf := make([]byte, overwriteChunk)
	for remaining > 0 {
		n := int64(len(buf))
		if remaining < n {
			n = remaining
		}
		if _, err := io.ReadFull(rand.Reader, buf[:n]); err != nil {
			return err
		}
		if _, err := f.Write(buf[:n]); err != nil {
			return err
		}
		remaining -= n
	}

	// Принудительно пишем изменения этого конкретного файла на диск
	return f.Sync()
}

// secureDeleteDir удаляет все файлы в директории, предварительно затирая их начало
func (p *PanicHandler) secureDeleteDir(dir string) error {
	if dir == "" {
		return nil
	}
	return filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil // игнорируем ошибки, продолжаем
		}

		if !info.IsDir() {
			if err := overwriteFile(path, attachmentHeaderSize); err != nil {
				log.Printf("⚠️ overwrite %s: %v", path, err)
			}
			os.Remove(path)
		}

		return nil
	})
}
