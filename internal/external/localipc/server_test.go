package localipc

import (
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"time-tracker/internal/application/usecases"
	"time-tracker/internal/external/duckdb"
)

func socketPath(t *testing.T) string {
	t.Helper()
	// Unix socket paths are limited to ~104 bytes on macOS, so keep the
	// directory short rather than using the long default test temp path.
	dir, err := os.MkdirTemp("", "ttipc")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return filepath.Join(dir, "ipc.sock")
}

func serveTestIngestion(t *testing.T, path string) (context.CancelFunc, <-chan error) {
	t.Helper()
	store, err := duckdb.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- Serve(ctx, path, NewIngestionHandler(usecases.NewIngestionUsecase(store))) }()
	waitForSocket(t, path)
	t.Cleanup(cancel)
	return cancel, done
}

func waitForSocket(t *testing.T, path string) {
	t.Helper()
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); {
		conn, err := net.Dial("unix", path)
		if err == nil {
			conn.Close()
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("socket %s never accepted connections", path)
}

func socketClient(path string) *http.Client {
	return &http.Client{Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", path)
		},
	}}
}

func TestServeAcceptsBatchesOnPrivateSocket(t *testing.T) {
	path := socketPath(t)
	serveTestIngestion(t, path)

	response, err := socketClient(path).Post("http://ipc/v1/events", "application/json", strings.NewReader(validBatch))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status: %d", response.StatusCode)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("socket permissions: %v; want 0600", info.Mode().Perm())
	}
}

func TestServeRefusesSocketOwnedByAnotherServer(t *testing.T) {
	path := socketPath(t)
	serveTestIngestion(t, path)

	err := Serve(context.Background(), path, http.NotFoundHandler())
	if !errors.Is(err, ErrSocketInUse) {
		t.Fatalf("second serve error: %v; want ErrSocketInUse", err)
	}

	response, err := socketClient(path).Post("http://ipc/v1/events", "application/json", strings.NewReader(validBatch))
	if err != nil {
		t.Fatalf("first server stopped serving: %v", err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status: %d", response.StatusCode)
	}
}

func TestServeReplacesSocketLeftByCrashedServer(t *testing.T) {
	path := socketPath(t)
	stale, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	// Close the listener's file descriptor without unlinking, the way an
	// unclean shutdown leaves the socket behind.
	stale.(*net.UnixListener).SetUnlinkOnClose(false)
	stale.Close()

	serveTestIngestion(t, path)
	response, err := socketClient(path).Post("http://ipc/v1/events", "application/json", strings.NewReader(validBatch))
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status: %d", response.StatusCode)
	}
}

func TestServeShutsDownAndRemovesSocketOnCancel(t *testing.T) {
	path := socketPath(t)
	cancel, done := serveTestIngestion(t, path)

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("serve: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("serve did not return after cancellation")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("socket still present after shutdown: %v", err)
	}
}

func TestServeRejectsPathThatIsNotASocket(t *testing.T) {
	path := socketPath(t)
	if err := os.WriteFile(path, []byte("not a socket"), 0o600); err != nil {
		t.Fatal(err)
	}
	err := Serve(context.Background(), path, http.NotFoundHandler())
	if err == nil || errors.Is(err, ErrSocketInUse) {
		t.Fatalf("serve error: %v; want a path conflict error", err)
	}
	if _, statErr := os.Stat(path); statErr != nil {
		t.Fatalf("existing file was removed: %v", statErr)
	}
}

func TestServeExplainsAPathTooLongForAUnixSocket(t *testing.T) {
	dir := t.TempDir()
	long := filepath.Join(dir, strings.Repeat("d", 120), "ipc.sock")
	err := Serve(context.Background(), long, http.NotFoundHandler())
	if err == nil {
		t.Fatal("expected an error for an over-long socket path")
	}
	if !strings.Contains(err.Error(), "too long") {
		t.Fatalf("error %q does not explain the length limit", err)
	}
}
