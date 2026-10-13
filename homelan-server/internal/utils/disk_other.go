//go:build !linux && !darwin && !freebsd && !netbsd && !openbsd && !windows

package utils

// HasEnoughSpace на платформах без Statfs всегда разрешает запись.
func HasEnoughSpace(path string, required int64) bool {
	return true
}
