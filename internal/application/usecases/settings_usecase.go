package usecases

import (
	"context"

	"time-tracker/internal/application/ports"
	"time-tracker/internal/domain"
)

type SettingsUsecase struct{ repo ports.SettingsRepository }

func NewSettingsUsecase(repo ports.SettingsRepository) *SettingsUsecase {
	return &SettingsUsecase{repo: repo}
}

func (u *SettingsUsecase) Load(ctx context.Context) (domain.Settings, string, error) {
	return u.repo.Load(ctx)
}
func (u *SettingsUsecase) Save(ctx context.Context, cfg domain.Settings) (string, error) {
	return u.repo.Save(ctx, cfg)
}
