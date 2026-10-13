//go:build linux || darwin || freebsd || netbsd || openbsd

package utils

import (
	"syscall"
)

// HasEnoughSpace проверяет, что на диске есть required байт плюс запас в 100 МБ.
// Если проверить не удалось — разрешаем запись (лучше попытаться, чем отказать).
func HasEnoughSpace(path string, required int64) bool {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return true
	}
	available := int64(stat.Bavail) * int64(stat.Bsize)
	return available > required+100*1024*1024
}
