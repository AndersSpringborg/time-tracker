package configfs

import (
	"path/filepath"
	"testing"
)

func TestSocketPathSitsBesideDatabaseWithoutColliding(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	dbPath, err := DBPath()
	if err != nil {
		t.Fatal(err)
	}
	socket, err := SocketPath()
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Dir(socket) != filepath.Dir(dbPath) {
		t.Fatalf("socket %s is not beside database %s", socket, dbPath)
	}
	if socket == dbPath {
		t.Fatal("socket path must not collide with the database path")
	}
}
