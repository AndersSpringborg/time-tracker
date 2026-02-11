package configfs

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"time-tracker/internal/domain"
)

type Repository struct{}

func New() *Repository { return &Repository{} }

func defaultSettings() domain.Settings {
	return domain.Settings{
		WorkWifis:             []string{},
		Enabled:               true,
		WeightedBucketMinutes: 5,
		WeightedSwitchMinutes: 10,
	}
}

func normalize(cfg domain.Settings) domain.Settings {
	if cfg.WorkWifis == nil {
		cfg.WorkWifis = []string{}
	}
	if cfg.WeightedBucketMinutes <= 0 {
		cfg.WeightedBucketMinutes = 5
	}
	if cfg.WeightedSwitchMinutes <= 0 {
		cfg.WeightedSwitchMinutes = 10
	}
	return cfg
}

func (r *Repository) Load(_ context.Context) (domain.Settings, string, error) {
	cfg := defaultSettings()
	path, err := ConfigPath()
	if err != nil {
		return cfg, "", err
	}
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return cfg, path, nil
		}
		return cfg, path, fmt.Errorf("read config: %w", err)
	}
	if len(b) == 0 {
		return cfg, path, nil
	}
	if err := json.Unmarshal(b, &cfg); err != nil {
		return defaultSettings(), path, fmt.Errorf("parse config: %w", err)
	}
	cfg = normalize(cfg)
	return cfg, path, nil
}

func (r *Repository) Save(_ context.Context, cfg domain.Settings) (string, error) {
	cfg = normalize(cfg)
	path, err := ConfigPath()
	if err != nil {
		return "", err
	}
	b, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return "", fmt.Errorf("marshal config: %w", err)
	}
	b = append(b, '\n')
	if err := os.WriteFile(path, b, 0o644); err != nil {
		return "", fmt.Errorf("write config: %w", err)
	}
	return path, nil
}

func ConfigPath() (string, error) {
	dir, err := configDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "config.json"), nil
}

func configDir() (string, error) {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		d := filepath.Join(xdg, "time-tracker")
		if err := os.MkdirAll(d, 0o755); err != nil {
			return "", err
		}
		return d, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	d := filepath.Join(home, ".config", "time-tracker")
	if err := os.MkdirAll(d, 0o755); err != nil {
		return "", err
	}
	return d, nil
}

func DBPath() (string, error) {
	if xdg := os.Getenv("XDG_DATA_HOME"); xdg != "" {
		d := filepath.Join(xdg, "time-tracker")
		if err := os.MkdirAll(d, 0o755); err != nil {
			return "", err
		}
		return filepath.Join(d, "tracker.db"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	d := filepath.Join(home, ".local", "share", "time-tracker")
	if err := os.MkdirAll(d, 0o755); err != nil {
		return "", err
	}
	return filepath.Join(d, "tracker.db"), nil
}
