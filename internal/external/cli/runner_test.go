package cli

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"time-tracker/internal/application/usecases"
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
