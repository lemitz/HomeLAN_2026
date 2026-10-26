package config

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

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
	// MaxFileMB — максимальный размер одного файла (МБ).
	MaxFileMB int `yaml:"max_file_mb"`
	// MaxSizeMB — устаревшее имя MaxFileMB (для старых конфигов).
	MaxSizeMB int `yaml:"max_size_mb"`
	// QuotaMB — общий лимит хранилища файлов (МБ). 0 = без лимита (только проверка диска).
	QuotaMB int `yaml:"quota_mb"`
	// RetentionDays — через сколько дней файлы удаляются. 0 = хранить всегда.
	RetentionDays int `yaml:"retention_days"`
}

type SecurityConfig struct {
	MaxUsers          int `yaml:"max_users"`
	MaxDevicesPerUser int `yaml:"max_devices_per_user"`
	SessionDays       int `yaml:"session_days"`
	// DuressPassword — пароль принуждения. Пусто = функция выключена.
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

// Default возвращает конфиг со значениями по умолчанию.
func Default() *Config {
	cfg := &Config{}
	cfg.applyDefaults()
	return cfg
}

func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read config: %w", err)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config: %w", err)
	}

	cfg.applyDefaults()
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func (c *Config) applyDefaults() {
	if c.Server.Port == 0 {
		c.Server.Port = 8080
	}
	if c.Database.Path == "" {
		c.Database.Path = "./data/messages.db"
	}
	if c.Files.StoragePath == "" {
		c.Files.StoragePath = "./data/files"
	}
	if c.Files.MaxFileMB == 0 {
		if c.Files.MaxSizeMB > 0 {
			c.Files.MaxFileMB = c.Files.MaxSizeMB
		} else {
			c.Files.MaxFileMB = 2048
		}
	}
	if c.Security.MaxUsers == 0 {
		c.Security.MaxUsers = 2
	}
	if c.Security.MaxDevicesPerUser == 0 {
		c.Security.MaxDevicesPerUser = 3
	}
	if c.Security.SessionDays == 0 {
		c.Security.SessionDays = 90
	}
	if c.Timeouts.ReadSeconds == 0 {
		c.Timeouts.ReadSeconds = 300
	}
	if c.Timeouts.WriteSeconds == 0 {
		c.Timeouts.WriteSeconds = 300
	}
	if c.Timeouts.IdleSeconds == 0 {
		c.Timeouts.IdleSeconds = 60
	}
	if c.DeadMan.TimeoutDays == 0 {
		c.DeadMan.TimeoutDays = 30
	}
}

// Validate проверяет значения, которые нельзя молча исправить.
func (c *Config) Validate() error {
	if c.Server.Port < 1 || c.Server.Port > 65535 {
		return fmt.Errorf("invalid server.port: %d", c.Server.Port)
	}
	if c.Security.MaxUsers < 1 {
		return fmt.Errorf("invalid security.max_users: %d", c.Security.MaxUsers)
	}
	if c.Security.MaxDevicesPerUser < 1 {
		return fmt.Errorf("invalid security.max_devices_per_user: %d", c.Security.MaxDevicesPerUser)
	}
	if c.Files.MaxFileMB < 1 {
		return fmt.Errorf("invalid files.max_file_mb: %d", c.Files.MaxFileMB)
	}
	if c.Files.QuotaMB < 0 || c.Files.RetentionDays < 0 {
		return fmt.Errorf("files.quota_mb and files.retention_days must be >= 0")
	}
	if c.DeadMan.TimeoutDays < 1 {
		return fmt.Errorf("invalid dead_man_switch.timeout_days: %d", c.DeadMan.TimeoutDays)
	}
	if c.Security.DuressPassword != "" && len(c.Security.DuressPassword) < 8 {
		return fmt.Errorf("security.duress_password must be at least 8 characters")
	}
	return nil
}

// MaxFileBytes — лимит одного файла в байтах.
func (c *Config) MaxFileBytes() int64 { return int64(c.Files.MaxFileMB) << 20 }

// QuotaBytes — общий лимит хранилища в байтах (0 = без лимита).
func (c *Config) QuotaBytes() int64 { return int64(c.Files.QuotaMB) << 20 }
