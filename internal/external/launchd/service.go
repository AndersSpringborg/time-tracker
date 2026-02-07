package launchd

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"strings"

	"time-tracker/internal/domain"
	"time-tracker/internal/external/configfs"
	"time-tracker/internal/external/workerembed"
)

const label = "com.time-tracker.worker"

type Service struct{}

func New() *Service { return &Service{} }

func (s *Service) Install(context.Context) error {
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
	if err := s.bootstrap(plistPath); err != nil {
		return err
	}
	return s.kickstart()
}

func (s *Service) Uninstall(context.Context) error {
	_ = s.bootout()
	if p, err := workerembed.LaunchAgentPath(); err == nil {
		_ = os.Remove(p)
	}
	if p, err := workerembed.WorkerPath(); err == nil {
		_ = os.Remove(p)
	}
	return nil
}

func (s *Service) Start(context.Context) error { return s.kickstart() }
func (s *Service) Stop(context.Context) error  { return s.kill() }

func (s *Service) Status(context.Context) domain.LifecycleStatus {
	st := domain.LifecycleStatus{State: "not_loaded"}
	target := fmt.Sprintf("gui/%s/%s", uid(), label)
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
	cmd := exec.Command("launchctl", "bootstrap", "gui/"+uid(), plistPath)
	if out, err := cmd.CombinedOutput(); err != nil {
		msg := strings.TrimSpace(string(out))
		if strings.Contains(msg, "already loaded") {
			return nil
		}
		return fmt.Errorf("launchctl bootstrap failed: %w: %s", err, msg)
	}
	return nil
}

func (s *Service) bootout() error {
	cmd := exec.Command("launchctl", "bootout", "gui/"+uid(), label)
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
	cmd := exec.Command("launchctl", "kickstart", "-k", "gui/"+uid()+"/"+label)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("launchctl kickstart failed: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (s *Service) kill() error {
	cmd := exec.Command("launchctl", "kill", "TERM", "gui/"+uid()+"/"+label)
	if out, err := cmd.CombinedOutput(); err != nil {
		msg := strings.TrimSpace(string(out))
		if strings.Contains(msg, "No such process") || strings.Contains(msg, "service not found") {
			return nil
		}
		return fmt.Errorf("launchctl kill failed: %w: %s", err, msg)
	}
	return nil
}

func uid() string {
	if n := os.Getuid(); n > 0 {
		return strconv.Itoa(n)
	}
	u, err := user.Current()
	if err == nil && u.Uid != "" {
		return u.Uid
	}
	return "501"
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
