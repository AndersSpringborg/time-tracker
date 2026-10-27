package usecases

import (
	"context"

	"time-tracker/internal/application/ports"
	"time-tracker/internal/domain"
)

// MaintenanceUsecase reports database size and rewrites the file to reclaim
// space. Both operations act on the database as a file, so they are defined
// against a port rather than the ordinary repository.
type MaintenanceUsecase struct {
	maintainer ports.DatabaseMaintainer
}

func NewMaintenanceUsecase(maintainer ports.DatabaseMaintainer) *MaintenanceUsecase {
	return &MaintenanceUsecase{maintainer: maintainer}
}

func (u *MaintenanceUsecase) Status(ctx context.Context) (domain.DatabaseStats, error) {
	return u.maintainer.Stats(ctx)
}

func (u *MaintenanceUsecase) Compact(ctx context.Context) (domain.CompactionResult, error) {
	return u.maintainer.Compact(ctx)
}
