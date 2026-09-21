package ports

import (
	"context"
	"time-tracker/internal/domain"
)

type IngestionRepository interface {
	IngestBatch(context.Context, domain.IngestBatch) (domain.IngestResult, error)
}
