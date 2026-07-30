//go:build linux

package utils

import (
	"syscall"
)

func HasEnoughSpace(path string, required int64) bool {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return true // если не смогли проверить — разрешаем
	}
	available := int64(stat.Bavail) * int64(stat.Bsize)
	return available > required+100*1024*1024
}