package usecases

import (
	"context"

	"time-tracker/internal/application/contracts"
	"time-tracker/internal/application/ports"
)

type SettingsUsecase struct{ repo ports.SettingsRepository }

func NewSettingsUsecase(repo ports.SettingsRepository) *SettingsUsecase {
	return &SettingsUsecase{repo: repo}
}

func (u *SettingsUsecase) Load(ctx context.Context, _ contracts.SettingsLoadRequest) (contracts.SettingsLoadResponse, error) {
	cfg, path, err := u.repo.Load(ctx)
	if err != nil {
		return contracts.SettingsLoadResponse{}, err
	}
	return contracts.SettingsLoadResponse{Settings: cfg, Path: path}, nil
}
func (u *SettingsUsecase) Save(ctx context.Context, req contracts.SettingsSaveRequest) (contracts.SettingsSaveResponse, error) {
	path, err := u.repo.Save(ctx, req.Settings)
	if err != nil {
		return contracts.SettingsSaveResponse{}, err
	}
	return contracts.SettingsSaveResponse{Path: path}, nil
}
