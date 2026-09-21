package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLocalCommandsWorkWhenDatabaseCannotBeOpened(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	t.Setenv("HOME", t.TempDir())
	// A directory at the database path cannot be opened as a DuckDB database.
	dbPath := filepath.Join(os.Getenv("XDG_DATA_HOME"), "time-tracker", "tracker.db")
	if err := os.MkdirAll(dbPath, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		args   []string
		code   int
		output string
	}{
		{nil, 0, "Usage:"},
		{[]string{"help", "--format", "json"}, 0, "commands"},
		{[]string{"schema", "rules"}, 0, "rules"},
		{[]string{"settings", "get", "enabled"}, 0, "true"},
		{[]string{"unknown"}, 2, "unknown command"},
	} {
		t.Run(strings.Join(tc.args, " "), func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			if code := run(tc.args, &stdout, &stderr); code != tc.code {
				t.Fatalf("exit = %d, want %d; stderr: %s", code, tc.code, &stderr)
			}
			if !strings.Contains(stdout.String()+stderr.String(), tc.output) {
				t.Fatalf("missing %q in stdout=%q stderr=%q", tc.output, &stdout, &stderr)
			}
		})
	}
}

func TestDatabaseCommandReportsOpenFailure(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	t.Setenv("HOME", t.TempDir())
	dbPath := filepath.Join(os.Getenv("XDG_DATA_HOME"), "time-tracker", "tracker.db")
	if err := os.MkdirAll(dbPath, 0o700); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	if code := run([]string{"reports"}, &stdout, &stderr); code != 1 {
		t.Fatalf("exit = %d, want 1", code)
	}
	if !strings.Contains(stderr.String(), "error:") {
		t.Fatalf("missing error: %s", &stderr)
	}
}
