package usecases

import (
	"context"
	"time-tracker/internal/application/ports"
	"time-tracker/internal/domain"
)

type IngestionUsecase struct{ repo ports.IngestionRepository }

func NewIngestionUsecase(repo ports.IngestionRepository) *IngestionUsecase {
	return &IngestionUsecase{repo: repo}
}

func (u *IngestionUsecase) Ingest(ctx context.Context, batch domain.IngestBatch) (domain.IngestResult, error) {
	if err := batch.Validate(); err != nil {
		return domain.IngestResult{}, err
	}
	return u.repo.IngestBatch(ctx, batch)
}
