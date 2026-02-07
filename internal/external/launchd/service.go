package launchd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"time-tracker/internal/domain"
	"time-tracker/internal/external/configfs"
	"time-tracker/internal/external/workerembed"
)

const label = "com.time-tracker.worker"

type Service struct{}

func New() *Service { return &Service{} }

func (s *Service) Install(context.Context) error {
	if err := rejectSudoInstall(); err != nil {
		return err
	}
	workerPath, err := workerembed.WorkerPath()
	if err != nil {
		return err
	}
	bin, err := workerembed.ResolveBinary()
	if err != nil {
		return err
	}
	if err := os.WriteFile(workerPath, bin, 0o755); err != nil {
		return err
	}

	plistPath, err := workerembed.LaunchAgentPath()
	if err != nil {
		return err
	}
	if _, err := configfs.DBPath(); err != nil {
		return err
	}
	if _, _, err := configfs.New().Load(context.Background()); err != nil {
		return err
	}
	plist, err := renderPlist(workerPath)
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
	if err := s.waitUntilLoaded(2 * time.Second); err != nil {
		return err
	}
	return s.kickstartWithRetry(10, 100*time.Millisecond)
}

func (s *Service) Uninstall(context.Context) error {
	if err := rejectSudoInstall(); err != nil {
		return err
	}
	_ = s.bootout()
	if p, err := workerembed.LaunchAgentPath(); err == nil {
		_ = os.Remove(p)
	}
	if p, err := workerembed.WorkerPath(); err == nil {
		_ = os.Remove(p)
	}
	return nil
}

func (s *Service) Start(context.Context) error {
	if err := rejectSudoInstall(); err != nil {
		return err
	}
	return s.kickstart()
}
func (s *Service) Stop(context.Context) error {
	if err := rejectSudoInstall(); err != nil {
		return err
	}
	return s.kill()
}

func (s *Service) Status(context.Context) domain.LifecycleStatus {
	st := domain.LifecycleStatus{State: "not_loaded"}
	serviceTarget, err := launchdServiceTarget()
	if err != nil {
		st.Raw = err.Error()
		return st
	}
	target := serviceTarget
	cmd := exec.Command("launchctl", "print", target)
	var out bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		st.Raw = strings.TrimSpace(out.String() + "\n" + stderr.String())
		return st
	}
	st.Loaded = true
	st.Raw = strings.TrimSpace(out.String())
	st.State = "loaded"
	for _, line := range strings.Split(st.Raw, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "state =") {
			parts := strings.SplitN(line, "=", 2)
			if len(parts) == 2 {
				state := strings.TrimSpace(parts[1])
				if state != "" {
					st.State = state
				}
			}
		}
		if strings.HasPrefix(line, "pid =") {
			parts := strings.SplitN(line, "=", 2)
			if len(parts) == 2 {
				st.PID = strings.TrimSpace(parts[1])
			}
		}
	}
	return st
}

func (s *Service) bootstrap(plistPath string) error {
	domainTarget, err := launchdDomainTarget()
	if err != nil {
		return err
	}
	cmd := exec.Command("launchctl", "bootstrap", domainTarget, plistPath)
	if out, err := cmd.CombinedOutput(); err != nil {
		msg := strings.TrimSpace(string(out))
		if strings.Contains(msg, "already loaded") {
			return nil
		}
		// launchd can return I/O error while the agent remains loaded.
		if strings.Contains(msg, "Input/output error") {
			if st := s.Status(context.Background()); st.Loaded {
				return nil
			}
		}
		return fmt.Errorf("launchctl bootstrap failed: %w: %s", err, msg)
	}
	return nil
}

func (s *Service) bootstrapWithRetry(plistPath string, attempts int, delay time.Duration) error {
	if attempts < 1 {
		attempts = 1
	}

	var lastErr error
	for range attempts {
		lastErr = s.bootstrap(plistPath)
		if lastErr == nil {
			return nil
		}
		if !strings.Contains(lastErr.Error(), "Input/output error") {
			return lastErr
		}
		time.Sleep(delay)
	}
	return lastErr
}

func (s *Service) bootout() error {
	serviceTarget, err := launchdServiceTarget()
	if err != nil {
		return err
	}
	cmd := exec.Command("launchctl", "bootout", serviceTarget)
	if out, err := cmd.CombinedOutput(); err != nil {
		msg := strings.TrimSpace(string(out))
		if strings.Contains(msg, "No such process") || strings.Contains(msg, "service not found") {
			return nil
		}
		return fmt.Errorf("launchctl bootout failed: %w: %s", err, msg)
	}
	return nil
}

func (s *Service) kickstart() error {
	serviceTarget, err := launchdServiceTarget()
	if err != nil {
		return err
	}
	cmd := exec.Command("launchctl", "kickstart", "-k", serviceTarget)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("launchctl kickstart failed: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (s *Service) kickstartWithRetry(attempts int, delay time.Duration) error {
	if attempts < 1 {
		attempts = 1
	}

	var lastErr error
	for range attempts {
		lastErr = s.kickstart()
		if lastErr == nil {
			return nil
		}
		if !strings.Contains(lastErr.Error(), "Could not find service") {
			return lastErr
		}
		time.Sleep(delay)
	}
	return lastErr
}

func (s *Service) kill() error {
	serviceTarget, err := launchdServiceTarget()
	if err != nil {
		return err
	}
	cmd := exec.Command("launchctl", "kill", "TERM", serviceTarget)
	if out, err := cmd.CombinedOutput(); err != nil {
		msg := strings.TrimSpace(string(out))
		if strings.Contains(msg, "No such process") || strings.Contains(msg, "service not found") {
			return nil
		}
		return fmt.Errorf("launchctl kill failed: %w: %s", err, msg)
	}
	return nil
}

func launchdServiceTarget() (string, error) {
	domainTarget, err := launchdDomainTarget()
	if err != nil {
		return "", err
	}
	return domainTarget + "/" + label, nil
}

func launchdDomainTarget() (string, error) {
	return launchdDomainTargetForUID(os.Getuid())
}

func rejectSudoInstall() error {
	return rejectSudoInstallForEUID(os.Geteuid())
}

func launchdDomainTargetForUID(uid int) (string, error) {
	if uid > 0 {
		return "gui/" + strconv.Itoa(uid), nil
	}
	return "", errors.New("launchd user domain unavailable: run tracker as your logged-in user (not root)")
}

func rejectSudoInstallForEUID(euid int) error {
	if euid == 0 {
		return errors.New("do not run with sudo: install/start/stop/uninstall use per-user LaunchAgent; run `./tracker install` as your normal user")
	}
	return nil
}

func (s *Service) waitUntilLoaded(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		st := s.Status(context.Background())
		if st.Loaded {
			return nil
		}
		if time.Now().After(deadline) {
			if st.Raw != "" {
				return fmt.Errorf("launchd agent was not loaded after bootstrap: %s", st.Raw)
			}
			return errors.New("launchd agent was not loaded after bootstrap")
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func renderPlist(workerPath string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	outLog := "/tmp/time-tracker-worker.log"
	errLog := "/tmp/time-tracker-worker.err.log"
	plist := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key>
  <array>
    <string>%s</string>
    <string>daemon</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>WorkingDirectory</key><string>%s</string>
  <key>StandardOutPath</key><string>%s</string>
  <key>StandardErrorPath</key><string>%s</string>
</dict>
</plist>
`, label, workerPath, home, outLog, errLog)
	return plist, nil
}
