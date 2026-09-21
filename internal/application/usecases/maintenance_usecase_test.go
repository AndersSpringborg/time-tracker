package usecases

import (
	"context"
	"errors"
	"testing"

	"time-tracker/internal/domain"
)

// fakeMaintainer stands in for the database file: maintenance is about a file
// that may be held by another process, which a real database cannot simulate.
type fakeMaintainer struct {
	stats        domain.DatabaseStats
	statsErr     error
	compacted    bool
	compactErr   error
	compactedRes domain.CompactionResult
}

func (f *fakeMaintainer) Stats(context.Context) (domain.DatabaseStats, error) {
	return f.stats, f.statsErr
}

func (f *fakeMaintainer) Compact(context.Context) (domain.CompactionResult, error) {
	if f.compactErr != nil {
		return domain.CompactionResult{}, f.compactErr
	}
	f.compacted = true
	return f.compactedRes, nil
}

func TestStatusReportsFileAndDataSizeSeparately(t *testing.T) {
	maintainer := &fakeMaintainer{stats: domain.DatabaseStats{
		Path: "/tmp/tracker.db", FileBytes: 19 << 30, EstimatedDataBytes: 25 << 20,
		Events: 303130, Reachable: true,
	}}
	usecase := NewMaintenanceUsecase(maintainer)

	status, err := usecase.Status(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if status.FileBytes == status.EstimatedDataBytes {
		t.Fatal("file size and data size must be reported separately")
	}
	if status.OverCap() {
		t.Fatal("25 MiB of data is far below the retention cap")
	}
}

func TestStatusReportsDataOverTheRetentionCap(t *testing.T) {
	maintainer := &fakeMaintainer{stats: domain.DatabaseStats{
		EstimatedDataBytes: domain.RetentionCapBytes + 1, Reachable: true,
	}}
	status, err := NewMaintenanceUsecase(maintainer).Status(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !status.OverCap() {
		t.Fatal("data above the cap must be reported as over cap")
	}
}

func TestCompactRefusesWhileTheCollectorHoldsTheDatabase(t *testing.T) {
	maintainer := &fakeMaintainer{compactErr: domain.ErrDatabaseBusy}
	usecase := NewMaintenanceUsecase(maintainer)

	_, err := usecase.Compact(context.Background())
	if !errors.Is(err, domain.ErrDatabaseBusy) {
		t.Fatalf("error: %v; want ErrDatabaseBusy", err)
	}
	if maintainer.compacted {
		t.Fatal("a busy database must not be rewritten")
	}
}

func TestCompactReportsReclaimedSpace(t *testing.T) {
	maintainer := &fakeMaintainer{compactedRes: domain.CompactionResult{
		BackupPath: "/tmp/tracker.db.backup-1", BytesBefore: 19 << 30, BytesAfter: 30 << 20,
		Rows: map[string]int64{"events": 303130},
	}}
	usecase := NewMaintenanceUsecase(maintainer)

	result, err := usecase.Compact(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !maintainer.compacted {
		t.Fatal("compaction did not run")
	}
	if result.Reclaimed() != (19<<30)-(30<<20) {
		t.Fatalf("reclaimed %d bytes", result.Reclaimed())
	}
	if result.BackupPath == "" {
		t.Fatal("the original database must be kept as a backup")
	}
}
