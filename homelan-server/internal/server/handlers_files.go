package server

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"homelan-server/internal/utils"
)

const diskReserve = 100 << 20 // всегда оставляем 100 МБ свободными

func newFileID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

// handleFileUpload принимает уже зашифрованный клиентом файл потоком
// (multipart, поле "file"), без буферизации в памяти и временных файлов Go.
func (s *Server) handleFileUpload(w http.ResponseWriter, r *http.Request) {
	sess := sessionFrom(r)
	maxFile := s.cfg.MaxFileBytes()

	// Загрузка большого файла по Wi-Fi может идти дольше ReadTimeout.
	rc := http.NewResponseController(w)
	rc.SetReadDeadline(time.Now().Add(6 * time.Hour))
	rc.SetWriteDeadline(time.Now().Add(6 * time.Hour))

	expected := r.ContentLength
	if expected > maxFile+64<<10 {
		writeError(w, &apiError{http.StatusRequestEntityTooLarge, "file_too_large", "file exceeds max_file_mb"})
		return
	}
	need := expected
	if need <= 0 {
		need = maxFile
	}
	if quota := s.cfg.QuotaBytes(); quota > 0 {
		used, err := s.db.TotalFileBytes()
		if err != nil {
			writeError(w, err)
			return
		}
		if used+need > quota {
			writeError(w, &apiError{http.StatusInsufficientStorage, "quota_exceeded", "file storage quota exceeded"})
			return
		}
	}

	dir := s.cfg.Files.StoragePath
	if err := os.MkdirAll(dir, 0700); err != nil {
		writeError(w, err)
		return
	}
	if !utils.HasEnoughSpace(dir, need+diskReserve) {
		writeError(w, &apiError{http.StatusInsufficientStorage, "disk_full", "insufficient disk space"})
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxFile+64<<10)
	mr, err := r.MultipartReader()
	if err != nil {
		writeError(w, errBadRequest("invalid_form", "multipart/form-data expected"))
		return
	}
	var part *multipart.Part
	for {
		p, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			writeError(w, errBadRequest("invalid_form", "malformed multipart body"))
			return
		}
		if p.FormName() == "file" {
			part = p
			break
		}
		p.Close()
	}
	if part == nil {
		writeError(w, errBadRequest("no_file", "field 'file' is required"))
		return
	}
	defer part.Close()

	fileID := newFileID()
	finalPath := filepath.Join(dir, fileID)
	tmpPath := finalPath + ".part"
	dst, err := os.OpenFile(tmpPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		writeError(w, err)
		return
	}
	written, copyErr := io.Copy(dst, io.LimitReader(part, maxFile+1))
	syncErr := dst.Sync()
	closeErr := dst.Close()
	cleanup := func() { os.Remove(tmpPath) }

	var mbe *http.MaxBytesError
	switch {
	case errors.As(copyErr, &mbe) || written > maxFile:
		cleanup()
		writeError(w, &apiError{http.StatusRequestEntityTooLarge, "file_too_large", "file exceeds max_file_mb"})
		return
	case copyErr != nil:
		cleanup()
		log.Printf("upload copy error: %v", copyErr)
		writeError(w, errBadRequest("upload_failed", "upload interrupted"))
		return
	case syncErr != nil || closeErr != nil:
		cleanup()
		writeError(w, errors.Join(syncErr, closeErr))
		return
	case written == 0:
		cleanup()
		writeError(w, errBadRequest("empty_file", "file is empty"))
		return
	}
	if err := os.Rename(tmpPath, finalPath); err != nil {
		cleanup()
		writeError(w, err)
		return
	}

	retention := time.Duration(s.cfg.Files.RetentionDays) * 24 * time.Hour
	if err := s.db.CreateFile(fileID, sess.UserID, written, finalPath, retention); err != nil {
		os.Remove(finalPath)
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"file_id": fileID, "size": written})
	log.Printf("📁 File uploaded: %s (%d bytes) by user %d", fileID, written, sess.UserID)
}

// handleFileDownload отдаёт зашифрованный файл с поддержкой Range.
func (s *Server) handleFileDownload(w http.ResponseWriter, r *http.Request) {
	sess := sessionFrom(r)
	fileID := r.PathValue("id")
	if !fileIDRe.MatchString(fileID) {
		writeError(w, errNotFound)
		return
	}
	f, err := s.db.GetFile(fileID)
	if err != nil {
		writeError(w, err)
		return
	}
	if f == nil {
		writeError(w, errNotFound)
		return
	}
	ok, err := s.db.CanAccessFile(f, sess.UserID)
	if err != nil {
		writeError(w, err)
		return
	}
	if !ok {
		writeError(w, errNotFound)
		return
	}
	if f.IsDeleted {
		writeError(w, &apiError{http.StatusGone, "file_deleted", "file has been deleted"})
		return
	}
	file, err := os.Open(f.StoragePath)
	if err != nil {
		writeError(w, &apiError{http.StatusGone, "file_missing", "file is missing on server"})
		return
	}
	defer file.Close()

	rc := http.NewResponseController(w)
	rc.SetWriteDeadline(time.Now().Add(6 * time.Hour))

	h := w.Header()
	h.Set("Content-Type", "application/octet-stream")
	h.Set("Content-Disposition", `attachment; filename="`+fileID+`.bin"`)
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Cache-Control", "no-store")
	http.ServeContent(w, r, "", time.Unix(f.CreatedAt, 0), file)
}
