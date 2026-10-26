//go:build windows

package panic

// syncFilesystem: на Windows нет глобального sync(2); каждый файл
// уже сброшен через f.Sync() в shredFile.
func syncFilesystem() {}
