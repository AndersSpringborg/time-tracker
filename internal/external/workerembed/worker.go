package workerembed

import (
	"errors"
	"os"
	"path/filepath"

	"time-tracker/internal/worker"
)

func ResolveBinary() ([]byte, error) {
	if len(worker.EmbeddedBinary) > 1024 {
		return worker.EmbeddedBinary, nil
	}
	candidates := []string{
		filepath.Join("zig-out", "bin", "tt"),
		"stable_time_tracker",
	}
	for _, c := range candidates {
		b, err := os.ReadFile(c)
		if err == nil && len(b) > 1024 {
			return b, nil
		}
	}
	return nil, errors.New("worker binary not found; run `zig build` and `make sync-worker`")
}

func WorkerPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	d := filepath.Join(home, ".local", "bin")
	if err := os.MkdirAll(d, 0o755); err != nil {
		return "", err
	}
	return filepath.Join(d, "tt-worker"), nil
}

func LaunchAgentPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	d := filepath.Join(home, "Library", "LaunchAgents")
	if err := os.MkdirAll(d, 0o755); err != nil {
		return "", err
	}
	return filepath.Join(d, "com.time-tracker.worker.plist"), nil
}
