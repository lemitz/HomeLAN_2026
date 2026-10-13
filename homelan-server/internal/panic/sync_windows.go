//go:build windows

package panic

// syncFilesystem: на Windows глобального sync() нет; каждый перезаписанный
// файл уже сброшен через File.Sync() в overwriteFile.
func syncFilesystem() {}
