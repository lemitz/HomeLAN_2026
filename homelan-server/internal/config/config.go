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
	MaxSizeMB   int    `yaml:"max_size_mb"`
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

func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read config: %w", err)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config: %w", err)
	}

	// Defaults
	if cfg.Server.Port == 0 {
		cfg.Server.Port = 8080
	}
	if cfg.DeadMan.TimeoutDays == 0 {
		cfg.DeadMan.TimeoutDays = 30
	}
	if cfg.Files.MaxSizeMB == 0 {
		cfg.Files.MaxSizeMB = 2048
	}
	if cfg.Security.MaxUsers == 0 {
		cfg.Security.MaxUsers = 2
	}

	return &cfg, nil
}

func (c *Config) Save(path string) error {
	data, err := yaml.Marshal(c)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0600)
}
