package config

import (
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

const (
	DefaultPort          = 8080
	DefaultDBPath        = "./data/messages.db"
	DefaultStoragePath   = "./data/files"
	DefaultMaxStorageMB  = 2048
	DefaultMaxFileSizeMB = 100
	DefaultMaxUsers      = 2
	DefaultDeadManDays   = 30
	DefaultReadSeconds   = 300
	DefaultWriteSeconds  = 300
	DefaultIdleSeconds   = 60

	// MinDuressPasswordLen — минимальная длина duress-пароля. Duress-пароль по сути
	// позволяет стереть сервер без аутентификации (нужно знать только имя пользователя),
	// поэтому короткий или типовой пароль недопустим.
	MinDuressPasswordLen = 8
)

// Известные «примерные» duress-пароли из документации/шаблонов, которые нельзя использовать.
var insecureDuressPasswords = map[string]bool{
	"panic123":    true,
	"panic":       true,
	"password":    true,
	"duress":      true,
	"12345678":    true,
	"changeme":    true,
	"change_me":   true,
	"your-secret": true,
}

type Config struct {
	Server   ServerConfig   `yaml:"server"`
	Database DatabaseConfig `yaml:"database"`
	Files    FilesConfig    `yaml:"files"`
	Security SecurityConfig `yaml:"security"`
	Timeouts TimeoutConfig  `yaml:"timeouts"`
	DeadMan  DeadManConfig  `yaml:"dead_man_switch"`
}

type ServerConfig struct {
	Host string `yaml:"host"`
	Port int    `yaml:"port"`
}

type DatabaseConfig struct {
	Path string `yaml:"path"`
}

type FilesConfig struct {
	StoragePath string `yaml:"storage_path"`
	// MaxSizeMB — общая квота хранилища вложений (сумма размеров неудалённых файлов)
	MaxSizeMB int `yaml:"max_size_mb"`
	// MaxFileSizeMB — максимальный размер одного файла
	MaxFileSizeMB int `yaml:"max_file_size_mb"`
}

type SecurityConfig struct {
	MaxUsers       int    `yaml:"max_users"`
	DuressPassword string `yaml:"duress_password"`
}

type TimeoutConfig struct {
	ReadSeconds  int `yaml:"read_seconds"`
	WriteSeconds int `yaml:"write_seconds"`
	IdleSeconds  int `yaml:"idle_seconds"`
}

type DeadManConfig struct {
	Enabled     bool `yaml:"enabled"`
	TimeoutDays int  `yaml:"timeout_days"`
}

// Load читает конфиг, подставляет значения по умолчанию и валидирует его.
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read config: %w", err)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config: %w", err)
	}

	cfg.ApplyDefaults()
	if err := cfg.Validate(); err != nil {
		return nil, err
	}

	return &cfg, nil
}

// ApplyDefaults заполняет незаданные поля значениями по умолчанию.
func (c *Config) ApplyDefaults() {
	if c.Server.Port == 0 {
		c.Server.Port = DefaultPort
	}
	if c.Database.Path == "" {
		c.Database.Path = DefaultDBPath
	}
	if c.Files.StoragePath == "" {
		c.Files.StoragePath = DefaultStoragePath
	}
	if c.Files.MaxSizeMB == 0 {
		c.Files.MaxSizeMB = DefaultMaxStorageMB
	}
	if c.Files.MaxFileSizeMB == 0 {
		c.Files.MaxFileSizeMB = DefaultMaxFileSizeMB
	}
	if c.Security.MaxUsers == 0 {
		c.Security.MaxUsers = DefaultMaxUsers
	}
	if c.DeadMan.TimeoutDays == 0 {
		c.DeadMan.TimeoutDays = DefaultDeadManDays
	}
	if c.Timeouts.ReadSeconds == 0 {
		c.Timeouts.ReadSeconds = DefaultReadSeconds
	}
	if c.Timeouts.WriteSeconds == 0 {
		c.Timeouts.WriteSeconds = DefaultWriteSeconds
	}
	if c.Timeouts.IdleSeconds == 0 {
		c.Timeouts.IdleSeconds = DefaultIdleSeconds
	}
}

// Validate проверяет согласованность конфига.
func (c *Config) Validate() error {
	if c.Server.Port < 1 || c.Server.Port > 65535 {
		return fmt.Errorf("server.port must be in 1..65535, got %d", c.Server.Port)
	}
	if c.Files.MaxFileSizeMB < 1 {
		return fmt.Errorf("files.max_file_size_mb must be >= 1")
	}
	if c.Files.MaxSizeMB < c.Files.MaxFileSizeMB {
		return fmt.Errorf("files.max_size_mb (%d) must be >= files.max_file_size_mb (%d)",
			c.Files.MaxSizeMB, c.Files.MaxFileSizeMB)
	}
	if c.Security.MaxUsers < 1 {
		return fmt.Errorf("security.max_users must be >= 1")
	}
	if c.DeadMan.TimeoutDays < 1 {
		return fmt.Errorf("dead_man_switch.timeout_days must be >= 1")
	}
	if c.Timeouts.ReadSeconds < 1 || c.Timeouts.WriteSeconds < 1 || c.Timeouts.IdleSeconds < 1 {
		return fmt.Errorf("timeouts must be positive")
	}
	if err := ValidateDuressPassword(c.Security.DuressPassword); err != nil {
		return err
	}
	return nil
}

// ValidateDuressPassword проверяет, что duress-пароль не пустой-по-ошибке, не слишком
// короткий и не является известным примером из документации. Пустое значение
// допустимо (функция выключена).
func ValidateDuressPassword(p string) error {
	if p == "" {
		return nil
	}
	if len(p) < MinDuressPasswordLen {
		return fmt.Errorf("security.duress_password is too short (min %d chars): anyone on the LAN who guesses it can wipe the server", MinDuressPasswordLen)
	}
	if insecureDuressPasswords[strings.ToLower(strings.TrimSpace(p))] {
		return fmt.Errorf("security.duress_password %q is a well-known example value — choose a unique one", p)
	}
	return nil
}

// MaxFileSizeBytes возвращает лимит одного файла в байтах.
func (c *Config) MaxFileSizeBytes() int64 {
	return int64(c.Files.MaxFileSizeMB) << 20
}

// MaxStorageBytes возвращает квоту хранилища в байтах.
func (c *Config) MaxStorageBytes() int64 {
	return int64(c.Files.MaxSizeMB) << 20
}

func (c *Config) Save(path string) error {
	data, err := yaml.Marshal(c)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0600)
}
