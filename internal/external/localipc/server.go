package localipc

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// ErrSocketInUse reports that another process is already serving the socket.
// The backend is the sole owner of the database, so a second server must fail
// loudly instead of taking the socket away from the running owner.
var ErrSocketInUse = errors.New("local ipc socket already in use")

const (
	requestTimeout  = 30 * time.Second
	idleTimeout     = 60 * time.Second
	shutdownTimeout = 5 * time.Second
	maxHeaderBytes  = 8 * 1024
	// Unix socket paths are limited by the kernel; macOS allows 104 bytes
	// including the terminator, and the failure is otherwise reported only as
	// "bind: invalid argument".
	maxSocketPathLen = 103
)

// Serve runs handler on a user-restricted Unix socket until ctx is cancelled.
// The socket is removed on return so a later start binds cleanly.
func Serve(ctx context.Context, socketPath string, handler http.Handler) error {
	listener, err := listen(socketPath)
	if err != nil {
		return err
	}
	server := &http.Server{
		Handler:        handler,
		ReadTimeout:    requestTimeout,
		WriteTimeout:   requestTimeout,
		IdleTimeout:    idleTimeout,
		MaxHeaderBytes: maxHeaderBytes,
	}
	served := make(chan error, 1)
	go func() { served <- server.Serve(listener) }()

	select {
	case err := <-served:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	err = server.Shutdown(shutdownCtx)
	<-served
	return err
}

func listen(socketPath string) (net.Listener, error) {
	if len(socketPath) > maxSocketPathLen {
		return nil, fmt.Errorf("socket path %s is too long: %d bytes, limit %d",
			socketPath, len(socketPath), maxSocketPathLen)
	}
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o700); err != nil {
		return nil, fmt.Errorf("create socket directory: %w", err)
	}
	if err := clearUnusedSocket(socketPath); err != nil {
		return nil, err
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return nil, fmt.Errorf("listen on %s: %w", socketPath, err)
	}
	if err := os.Chmod(socketPath, 0o600); err != nil {
		listener.Close()
		return nil, fmt.Errorf("restrict %s: %w", socketPath, err)
	}
	return listener, nil
}

// clearUnusedSocket removes a socket left behind by an unclean shutdown. It
// refuses to touch a socket with a live server or a path holding another file.
func clearUnusedSocket(socketPath string) error {
	info, err := os.Lstat(socketPath)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect %s: %w", socketPath, err)
	}
	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("refusing to replace %s: not a socket", socketPath)
	}
	conn, err := net.DialTimeout("unix", socketPath, time.Second)
	if err == nil {
		conn.Close()
		return fmt.Errorf("%w: %s", ErrSocketInUse, socketPath)
	}
	if err := os.Remove(socketPath); err != nil {
		return fmt.Errorf("remove stale socket %s: %w", socketPath, err)
	}
	return nil
}
