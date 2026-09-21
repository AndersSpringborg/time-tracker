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

// RetentionRepository serves the cap-driven retention policy: how much detail
// is stored, which days could be summarised, and the summarisation itself.
type RetentionRepository interface {
	DetailBytes(context.Context) (int64, error)
	RetentionDays(context.Context) ([]domain.RetentionDay, error)
	SummarizeDay(context.Context, string) (domain.DaySummary, error)
}
