package workerembed

import (
	"os"
	"path/filepath"
	"testing"

	"time-tracker/internal/worker"
)

func TestResolveBinaryUsesEmbeddedWhenPresent(t *testing.T) {
	original := worker.EmbeddedBinary
	t.Cleanup(func() { worker.EmbeddedBinary = original })

	worker.EmbeddedBinary = bytesOfSize(2048, 0x42)

	got, err := ResolveBinary()
	if err != nil {
		t.Fatalf("resolve embedded binary: %v", err)
	}
	if len(got) != 2048 || got[0] != 0x42 {
		t.Fatalf("unexpected embedded payload")
	}
}

func TestResolveBinaryFallsBackToZigOutBinary(t *testing.T) {
	original := worker.EmbeddedBinary
	t.Cleanup(func() { worker.EmbeddedBinary = original })
	worker.EmbeddedBinary = []byte("tiny")

	prevWd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	tmp := t.TempDir()
	if err := os.Chdir(tmp); err != nil {
		t.Fatalf("chdir temp: %v", err)
	}
	t.Cleanup(func() { _ = os.Chdir(prevWd) })

	binPath := filepath.Join("zig-out", "bin", "tt")
	if err := os.MkdirAll(filepath.Dir(binPath), 0o755); err != nil {
		t.Fatalf("mkdir zig-out/bin: %v", err)
	}
	want := bytesOfSize(2048, 0x66)
	if err := os.WriteFile(binPath, want, 0o755); err != nil {
		t.Fatalf("write fallback binary: %v", err)
	}

	got, err := ResolveBinary()
	if err != nil {
		t.Fatalf("resolve fallback binary: %v", err)
	}
	if len(got) != len(want) || got[0] != want[0] {
		t.Fatalf("unexpected fallback payload")
	}
}

func TestResolveBinaryReturnsErrorWithoutAnyCandidates(t *testing.T) {
	original := worker.EmbeddedBinary
	t.Cleanup(func() { worker.EmbeddedBinary = original })
	worker.EmbeddedBinary = []byte("tiny")

	prevWd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	tmp := t.TempDir()
	if err := os.Chdir(tmp); err != nil {
		t.Fatalf("chdir temp: %v", err)
	}
	t.Cleanup(func() { _ = os.Chdir(prevWd) })

	_, err = ResolveBinary()
	if err == nil {
		t.Fatalf("expected missing worker error")
	}
}

func bytesOfSize(n int, b byte) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = b
	}
	return out
}
