//go:build !windows

package panic

import "syscall"

// syncFilesystem сбрасывает буферы ФС на диск (важно для SD-карт).
func syncFilesystem() { syscall.Sync() }
