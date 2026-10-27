package launchd

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"time-tracker/internal/domain"
	"time-tracker/internal/external/workerembed"
)

// BackendLaunchAgentPath is the plist for the always-on backend agent. It sits
// beside the collector's so the two can be loaded and unloaded independently.
func BackendLaunchAgentPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(home, "Library", "LaunchAgents")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return filepath.Join(dir, backendLabel+".plist"), nil
}

// InstallBackend writes and loads the agent that keeps `tracker serve`
// listening. The collector delivers its outbox over that service's socket, so
// ingestion must be running whenever the collector is.
func (s *Service) InstallBackend(ctx context.Context) error {
	if err := rejectSudoInstall(); err != nil {
		return err
	}
	binary, err := trackerBinaryPath()
	if err != nil {
		return err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	plist, err := renderBackendPlist(binary, home)
	if err != nil {
		return err
	}
	plistPath, err := BackendLaunchAgentPath()
	if err != nil {
		return err
	}
	if err := os.WriteFile(plistPath, []byte(plist), 0o644); err != nil {
		return err
	}

	_ = s.bootout()
	if err := s.bootstrapWithRetry(plistPath, 12, 100*time.Millisecond); err != nil {
		return err
	}
	return s.waitUntilLoaded(2 * time.Second)
}

// trackerBinaryPath resolves the Go binary the agent should run. The running
// executable is preferred so the agent tracks whatever was just installed.
func trackerBinaryPath() (string, error) {
	if executable, err := os.Executable(); err == nil {
		if resolved, err := filepath.EvalSymlinks(executable); err == nil {
			return resolved, nil
		}
		return executable, nil
	}
	found, err := exec.LookPath("tracker")
	if err != nil {
		return "", fmt.Errorf("cannot locate the tracker binary for the backend agent: %w", err)
	}
	return found, nil
}

func renderBackendPlist(binaryPath, home string) (string, error) {
	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key>
  <array>
    <string>%s</string>
    <string>serve</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>WorkingDirectory</key><string>%s</string>
  <key>StandardOutPath</key><string>/tmp/time-tracker-backend.log</string>
  <key>StandardErrorPath</key><string>/tmp/time-tracker-backend.err.log</string>
</dict>
</plist>
`, backendLabel, binaryPath, home), nil
}

// UninstallBackend stops the agent and removes its plist.
func (s *Service) UninstallBackend(context.Context) error {
	if err := rejectSudoInstall(); err != nil {
		return err
	}
	_ = s.bootout()
	if path, err := BackendLaunchAgentPath(); err == nil {
		_ = os.Remove(path)
	}
	return nil
}

func workerLaunchAgentPathForTest() (string, error) {
	return workerembed.LaunchAgentPath()
}

// Agents drives both per-user LaunchAgents as one lifecycle. The collector
// delivers its outbox through the backend's socket, so the two are installed
// and started together; only the collector is stopped by `stop`, because the
// backend also serves the web UI and the CLI.
type Agents struct {
	collector *Service
	backend   *Service
}

func NewAgents() *Agents { return &Agents{collector: New(), backend: NewBackend()} }

func (a *Agents) Install(ctx context.Context) error {
	// Backend first: the collector's socket must exist before it starts.
	if err := a.backend.InstallBackend(ctx); err != nil {
		return fmt.Errorf("install backend agent: %w", err)
	}
	return a.collector.Install(ctx)
}

func (a *Agents) Uninstall(ctx context.Context) error {
	if err := a.collector.Uninstall(ctx); err != nil {
		return err
	}
	return a.backend.UninstallBackend(ctx)
}

func (a *Agents) Start(ctx context.Context) error {
	if err := a.backend.Start(ctx); err != nil {
		return fmt.Errorf("start backend agent: %w", err)
	}
	return a.collector.Start(ctx)
}

// Stop stops collection only. Ingestion, reporting and the web UI stay up.
func (a *Agents) Stop(ctx context.Context) error { return a.collector.Stop(ctx) }

// Status reports the collector, which is what "is it tracking?" means.
func (a *Agents) Status(ctx context.Context) domain.LifecycleStatus {
	return a.collector.Status(ctx)
}
