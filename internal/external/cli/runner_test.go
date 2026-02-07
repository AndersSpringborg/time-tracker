package cli

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"time-tracker/internal/application/usecases"
	"time-tracker/internal/domain"
)

func TestRunnerHelpJSONForRules(t *testing.T) {
	r := &Runner{App: &usecases.App{Help: usecases.NewHelpUsecase()}}
	var out bytes.Buffer
	var errOut bytes.Buffer

	code := r.Run(context.Background(), []string{"help", "--format", "json", "rules"}, &out, &errOut)
	if code != 0 {
		t.Fatalf("expected exit code 0, got %d stderr=%s", code, errOut.String())
	}
	if !strings.Contains(out.String(), `"command": "rules"`) {
		t.Fatalf("expected rules schema json, got: %s", out.String())
	}
	if !strings.Contains(out.String(), `"side_effects"`) {
		t.Fatalf("expected side_effects in output")
	}
}

type fakeLifecycle struct {
	installErr error
	status     domain.LifecycleStatus
}

func (f *fakeLifecycle) Install(context.Context) error                 { return f.installErr }
func (f *fakeLifecycle) Uninstall(context.Context) error               { return nil }
func (f *fakeLifecycle) Start(context.Context) error                   { return nil }
func (f *fakeLifecycle) Stop(context.Context) error                    { return nil }
func (f *fakeLifecycle) Status(context.Context) domain.LifecycleStatus { return f.status }

func TestRunnerStatusPrintsAccessibilityHintWhenNoPID(t *testing.T) {
	tmp := t.TempDir()
	errLog := filepath.Join(tmp, "worker.err.log")
	if err := os.WriteFile(errLog, []byte("ERROR: Accessibility permission required!"), 0o644); err != nil {
		t.Fatalf("write err log: %v", err)
	}

	orig := workerErrLogPath
	workerErrLogPath = errLog
	t.Cleanup(func() { workerErrLogPath = orig })

	lc := &fakeLifecycle{status: domain.LifecycleStatus{Loaded: true, State: "spawn scheduled"}}
	r := &Runner{
		App: &usecases.App{
			Lifecycle: usecases.NewLifecycleUsecase(lc),
		},
		WorkerPath: "/Users/test/.local/bin/tt-worker",
	}

	var out bytes.Buffer
	var errOut bytes.Buffer
	code := r.Run(context.Background(), []string{"status"}, &out, &errOut)
	if code != 0 {
		t.Fatalf("expected exit code 0, got %d stderr=%s", code, errOut.String())
	}

	got := out.String()
	if !strings.Contains(got, "accessibility-worker: /Users/test/.local/bin/tt-worker") {
		t.Fatalf("expected accessibility worker hint, got: %s", got)
	}
	if !strings.Contains(got, "worker log indicates missing Accessibility permission") {
		t.Fatalf("expected accessibility log hint, got: %s", got)
	}
}

func TestRunnerInstallPrintsAccessibilityHint(t *testing.T) {
	lc := &fakeLifecycle{}
	r := &Runner{
		App: &usecases.App{
			Lifecycle: usecases.NewLifecycleUsecase(lc),
		},
		WorkerPath: "/Users/test/.local/bin/tt-worker",
	}

	var out bytes.Buffer
	var errOut bytes.Buffer
	code := r.Run(context.Background(), []string{"install"}, &out, &errOut)
	if code != 0 {
		t.Fatalf("expected exit code 0, got %d stderr=%s", code, errOut.String())
	}

	got := out.String()
	if !strings.Contains(got, "installed and started launchd worker") {
		t.Fatalf("expected install success output, got: %s", got)
	}
	if !strings.Contains(got, "accessibility-worker: /Users/test/.local/bin/tt-worker") {
		t.Fatalf("expected accessibility hint, got: %s", got)
	}
}
