package duckdb

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	"time-tracker/internal/domain"
)

func TestMaintainerStatsSeparatesFileSizeFromDataSize(t *testing.T) {
	path := seedCompactionFixture(t, 100)
	maintainer := NewMaintainer(path)

	stats, err := maintainer.Stats(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !stats.Reachable {
		t.Fatal("a database nothing holds must be reachable")
	}
	if stats.Events != 100 {
		t.Fatalf("events=%d; want 100", stats.Events)
	}
	if stats.FileBytes <= 0 || stats.EstimatedDataBytes <= 0 {
		t.Fatalf("sizes not reported: %+v", stats)
	}
	if stats.EstimatedDataBytes >= stats.FileBytes {
		t.Fatalf("100 rows should estimate far below the file size: %+v", stats)
	}
	if stats.FirstDay == "" || stats.LastDay == "" {
		t.Fatalf("day span not reported: %+v", stats)
	}
	if stats.OverCap() {
		t.Fatal("100 events cannot exceed the retention cap")
	}
}

func TestMaintainerStatsReportsFileSizeWhenTheDatabaseCannotBeRead(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tracker.db")
	if err := writeFile(path, "not a database"); err != nil {
		t.Fatal(err)
	}
	stats, err := NewMaintainer(path).Stats(context.Background())
	if err != nil {
		t.Fatalf("stats must degrade rather than fail: %v", err)
	}
	if stats.Reachable {
		t.Fatal("an unreadable database must not be reported as reachable")
	}
	if stats.FileBytes == 0 {
		t.Fatal("file size is knowable without opening the database")
	}
}

func TestMaintainerReportsALockedDatabaseAsBusy(t *testing.T) {
	conflict := errors.New(`could not connect to database: IO Error: Could not set lock on file "tracker.db": Conflicting lock is held in /usr/bin/tt (PID 1)`)
	if !errors.Is(asBusy(conflict), domain.ErrDatabaseBusy) {
		t.Fatal("a conflicting lock must be reported as a busy database")
	}
	if errors.Is(asBusy(errors.New("disk full")), domain.ErrDatabaseBusy) {
		t.Fatal("unrelated failures must not be reported as busy")
	}
}

func TestMaintainerCompactsThroughThePort(t *testing.T) {
	path := seedCompactionFixture(t, 20)
	result, err := NewMaintainer(path).Compact(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if result.Rows["events"] != 20 || result.BackupPath == "" {
		t.Fatalf("unexpected result: %+v", result)
	}
}
