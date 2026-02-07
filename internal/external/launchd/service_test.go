package launchd

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLaunchdDomainTargetForUID(t *testing.T) {
	got, err := launchdDomainTargetForUID(501)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "gui/501" {
		t.Fatalf("expected gui/501, got %q", got)
	}
}

func TestLaunchdDomainTargetForUIDRejectsRoot(t *testing.T) {
	_, err := launchdDomainTargetForUID(0)
	if err == nil {
		t.Fatalf("expected error for uid 0")
	}
}

func TestRejectSudoInstallForEUID(t *testing.T) {
	if err := rejectSudoInstallForEUID(501); err != nil {
		t.Fatalf("unexpected error for user euid: %v", err)
	}
	if err := rejectSudoInstallForEUID(0); err == nil {
		t.Fatalf("expected error for root euid")
	}
}

func TestDeployWorkerBinaryWritesWhenMissing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tt-worker")
	payload := bytesOfSize(2048, 0x41)

	if err := deployWorkerBinary(path, payload); err != nil {
		t.Fatalf("deploy should write missing file: %v", err)
	}

	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read worker: %v", err)
	}
	if len(got) != len(payload) {
		t.Fatalf("unexpected worker size: got=%d want=%d", len(got), len(payload))
	}
}

func TestDeployWorkerBinaryPreservesExistingTrustedBinary(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tt-worker")
	existing := bytesOfSize(2048, 0x11)
	desired := bytesOfSize(2048, 0x22)
	if err := os.WriteFile(path, existing, 0o755); err != nil {
		t.Fatalf("seed worker: %v", err)
	}

	if err := deployWorkerBinary(path, desired); err != nil {
		t.Fatalf("deploy should preserve existing worker: %v", err)
	}

	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read worker: %v", err)
	}
	if got[0] != existing[0] {
		t.Fatalf("existing worker should be preserved")
	}
}

func TestDeployWorkerBinaryReplacesPlaceholder(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tt-worker")
	placeholder := []byte("placeholder")
	desired := bytesOfSize(2048, 0x33)
	if err := os.WriteFile(path, placeholder, 0o644); err != nil {
		t.Fatalf("seed placeholder: %v", err)
	}

	if err := deployWorkerBinary(path, desired); err != nil {
		t.Fatalf("deploy should replace placeholder: %v", err)
	}

	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read worker: %v", err)
	}
	if len(got) != len(desired) || got[0] != desired[0] {
		t.Fatalf("placeholder should be replaced with desired payload")
	}
}

func bytesOfSize(n int, b byte) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = b
	}
	return out
}
