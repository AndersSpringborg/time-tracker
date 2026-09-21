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

// DaySummary is the outcome of folding one day of detail into summaries.
type DaySummary struct {
	Day        string
	EventCount int64
	TotalMS    int64
}

// RetentionDay is one day of detail considered for summarisation.
type RetentionDay struct {
	Day            string
	Events         int64
	TotalMS        int64
	EstimatedBytes int64
	UnmappedEvents int64
}

// RetentionPlan is what retention would do at the current data size. It is
// produced without changing anything.
type RetentionPlan struct {
	DataBytes      int64
	CapBytes       int64
	Days           []RetentionDay
	Events         int64
	UnmappedEvents int64
	ReclaimedBytes int64
}

// OverCapBy reports how far stored detail exceeds the cap.
func (p RetentionPlan) OverCapBy() int64 {
	if p.DataBytes <= p.CapBytes {
		return 0
	}
	return p.DataBytes - p.CapBytes
}

// RetentionOutcome records what summarisation actually did.
type RetentionOutcome struct {
	Plan       RetentionPlan
	Summarized []DaySummary
}
