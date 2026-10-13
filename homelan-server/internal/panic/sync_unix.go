//go:build !windows

package panic

import "syscall"

// syncFilesystem сбрасывает все файловые буферы ОС на диск
func syncFilesystem() {
	syscall.Sync()
}
