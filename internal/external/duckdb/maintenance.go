package duckdb

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"strings"

	"time-tracker/internal/domain"
)

// bytesPerEventRow approximates the fixed-width columns of an event (ids,
// timestamps, durations, flags). Text is measured exactly and added to it.
const bytesPerEventRow = 64

// Maintainer implements the database-file side of maintenance. It holds no
// connection: compaction needs the file to itself, and status must work while
// the collector has it open.
type Maintainer struct {
	path string
}

func NewMaintainer(path string) *Maintainer { return &Maintainer{path: path} }

func (m *Maintainer) Stats(ctx context.Context) (domain.DatabaseStats, error) {
	stats := domain.DatabaseStats{Path: m.path}
	info, err := os.Stat(m.path)
	if err != nil {
		return stats, fmt.Errorf("stat database: %w", err)
	}
	stats.FileBytes = info.Size()

	db, err := sql.Open("duckdb", m.path)
	if err != nil {
		return stats, nil
	}
	defer db.Close()

	var textBytes sql.NullInt64
	var firstDay, lastDay sql.NullString
	err = db.QueryRowContext(ctx, `
		SELECT count(*),
		       coalesce(sum(length(app_name) + length(window_title) + length(coalesce(wifi_ssid, ''))), 0),
		       min(strftime(to_timestamp(timestamp_ms / 1000), '%Y-%m-%d')),
		       max(strftime(to_timestamp(timestamp_ms / 1000), '%Y-%m-%d'))
		FROM events`).Scan(&stats.Events, &textBytes, &firstDay, &lastDay)
	if err != nil {
		// The file exists but cannot be read right now, normally because the
		// collector holds it. The size above is still worth reporting.
		return stats, nil
	}
	stats.Reachable = true
	stats.EstimatedDataBytes = stats.Events*bytesPerEventRow + textBytes.Int64
	stats.FirstDay, stats.LastDay = firstDay.String, lastDay.String
	return stats, nil
}

func (m *Maintainer) Compact(ctx context.Context) (domain.CompactionResult, error) {
	result, err := Compact(ctx, m.path)
	if err != nil {
		return domain.CompactionResult{}, asBusy(err)
	}
	return domain.CompactionResult{
		BackupPath:    result.BackupPath,
		SchemaVersion: result.SchemaVersion,
		Rows:          result.Rows,
		BytesBefore:   result.BytesBefore,
		BytesAfter:    result.BytesAfter,
	}, nil
}

// asBusy recognises DuckDB's file-lock conflict so callers can tell "stop the
// collector first" apart from a real failure.
func asBusy(err error) error {
	if err == nil {
		return nil
	}
	if strings.Contains(err.Error(), "Conflicting lock") {
		return fmt.Errorf("%w: %v", domain.ErrDatabaseBusy, err)
	}
	return err
}
