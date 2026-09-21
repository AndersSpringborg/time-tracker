package ports

import (
	"context"
	"time-tracker/internal/domain"
)

type IngestionRepository interface {
	IngestBatch(context.Context, domain.IngestBatch) (domain.IngestResult, error)
}

// DatabaseMaintainer owns the database file itself: its size, and rewriting it
// to reclaim space DuckDB does not release.
type DatabaseMaintainer interface {
	Stats(context.Context) (domain.DatabaseStats, error)
	Compact(context.Context) (domain.CompactionResult, error)
}
