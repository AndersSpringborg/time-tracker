package duckdb

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// seedCompactionFixture writes a database with rows in several tables and
// returns its path.
func seedCompactionFixture(t *testing.T, events int) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "tracker.db")
	store, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	seedProjectActivity(t, store)
	for i := 0; i < events; i++ {
		_, err := store.db.Exec(
			`INSERT INTO events (timestamp_ms, app_name, window_title, duration_ms, wifi_ssid)
			 VALUES (?, 'Editor', 'file.go', 60000, 'Office')`, int64(1_700_000_000_000+i*1000))
		if err != nil {
			t.Fatal(err)
		}
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}

func countRows(t *testing.T, path, table string) int64 {
	t.Helper()
	db, err := sql.Open("duckdb", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var count int64
	if err := db.QueryRow(`SELECT count(*) FROM ` + table).Scan(&count); err != nil {
		t.Fatal(err)
	}
	return count
}

func TestCompactPreservesRowsMigrationsAndSequences(t *testing.T) {
	path := seedCompactionFixture(t, 50)

	result, err := Compact(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}

	if got := countRows(t, path, "events"); got != 50 {
		t.Fatalf("events after compaction: %d; want 50", got)
	}
	if got := countRows(t, path, "projects"); got == 0 {
		t.Fatal("projects were lost by compaction")
	}
	if result.BackupPath == "" {
		t.Fatal("compaction must keep a backup of the original database")
	}
	if _, err := os.Stat(result.BackupPath); err != nil {
		t.Fatalf("backup missing: %v", err)
	}

	// The compacted database must still be usable: migrations already applied,
	// and the events sequence must not hand out an id that already exists.
	store, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	var version int64
	if err := store.db.QueryRow(`SELECT max(version) FROM schema_migrations`).Scan(&version); err != nil {
		t.Fatal(err)
	}
	if version != result.SchemaVersion {
		t.Fatalf("schema version %d; want %d", version, result.SchemaVersion)
	}
	if _, err := store.db.Exec(
		`INSERT INTO events (timestamp_ms, app_name, window_title, duration_ms)
		 VALUES (1, 'A', 'B', 1)`); err != nil {
		t.Fatalf("insert after compaction: %v", err)
	}
	var distinct, total int64
	if err := store.db.QueryRow(`SELECT count(DISTINCT id), count(*) FROM events`).Scan(&distinct, &total); err != nil {
		t.Fatal(err)
	}
	if distinct != total {
		t.Fatalf("duplicate ids after compaction: %d distinct of %d", distinct, total)
	}
}

func TestCompactReportsReclaimedSize(t *testing.T) {
	path := seedCompactionFixture(t, 10)
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}

	result, err := Compact(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	if result.BytesBefore != before.Size() {
		t.Fatalf("BytesBefore=%d; want %d", result.BytesBefore, before.Size())
	}
	after, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if result.BytesAfter != after.Size() {
		t.Fatalf("BytesAfter=%d; want %d", result.BytesAfter, after.Size())
	}
	if result.Rows["events"] != 10 {
		t.Fatalf("reported events=%d; want 10", result.Rows["events"])
	}
}

func TestCompactLeavesTheDatabaseUntouchedWhenItCannotOpenIt(t *testing.T) {
	path := filepath.Join(t.TempDir(), "not-a-database.db")
	if err := os.WriteFile(path, []byte("this is not duckdb"), 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := Compact(context.Background(), path); err == nil {
		t.Fatal("expected compaction to fail on an unreadable database")
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "this is not duckdb" {
		t.Fatalf("original file was modified: %q", content)
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.Contains(entry.Name(), "compact") {
			t.Fatalf("failed compaction left %s behind", entry.Name())
		}
	}
}

func writeFile(path, content string) error {
	return os.WriteFile(path, []byte(content), 0o600)
}
