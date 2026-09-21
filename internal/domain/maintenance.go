package domain

import "errors"

// ErrDatabaseBusy reports that maintenance could not reach the database
// because another process (normally the collector) holds it.
var ErrDatabaseBusy = errors.New("database is in use by another process")

// DatabaseStats separates the physical file from the data it holds. DuckDB does
// not return freed space to the operating system, so the two diverge and the
// difference is what compaction reclaims.
type DatabaseStats struct {
	Path               string
	FileBytes          int64
	EstimatedDataBytes int64
	Events             int64
	FirstDay           string
	LastDay            string
	Reachable          bool
}

// RetentionCapBytes is the configured ceiling on detail data. It governs the
// data, not the file: exceeding it summarises and deletes the oldest detail.
const RetentionCapBytes int64 = 5 * 1024 * 1024 * 1024

// OverCap reports whether stored detail exceeds the retention cap.
func (s DatabaseStats) OverCap() bool {
	return s.EstimatedDataBytes > RetentionCapBytes
}

// CompactionResult records what a compaction rewrote.
type CompactionResult struct {
	BackupPath    string
	SchemaVersion int64
	Rows          map[string]int64
	BytesBefore   int64
	BytesAfter    int64
}

// Reclaimed reports the bytes returned to the filesystem.
func (r CompactionResult) Reclaimed() int64 {
	if r.BytesAfter > r.BytesBefore {
		return 0
	}
	return r.BytesBefore - r.BytesAfter
}
