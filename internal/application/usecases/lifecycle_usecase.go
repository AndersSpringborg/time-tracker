package usecases

import (
	"context"

	"time-tracker/internal/application/contracts"
	"time-tracker/internal/application/ports"
)

type LifecycleUsecase struct{ lifecycle ports.LifecyclePort }

func NewLifecycleUsecase(l ports.LifecyclePort) *LifecycleUsecase {
	return &LifecycleUsecase{lifecycle: l}
}

func (u *LifecycleUsecase) Install(ctx context.Context, _ contracts.LifecycleInstallRequest) (contracts.LifecycleInstallResponse, error) {
	if err := u.lifecycle.Install(ctx); err != nil {
		return contracts.LifecycleInstallResponse{}, err
	}
	return contracts.LifecycleInstallResponse{}, nil
}

func (u *LifecycleUsecase) Uninstall(ctx context.Context, _ contracts.LifecycleUninstallRequest) (contracts.LifecycleUninstallResponse, error) {
	if err := u.lifecycle.Uninstall(ctx); err != nil {
		return contracts.LifecycleUninstallResponse{}, err
	}
	return contracts.LifecycleUninstallResponse{}, nil
}

func (u *LifecycleUsecase) Start(ctx context.Context, _ contracts.LifecycleStartRequest) (contracts.LifecycleStartResponse, error) {
	if err := u.lifecycle.Start(ctx); err != nil {
		return contracts.LifecycleStartResponse{}, err
	}
	return contracts.LifecycleStartResponse{}, nil
}

func (u *LifecycleUsecase) Stop(ctx context.Context, _ contracts.LifecycleStopRequest) (contracts.LifecycleStopResponse, error) {
	if err := u.lifecycle.Stop(ctx); err != nil {
		return contracts.LifecycleStopResponse{}, err
	}
	return contracts.LifecycleStopResponse{}, nil
}

func (u *LifecycleUsecase) Status(ctx context.Context, _ contracts.LifecycleStatusRequest) (contracts.LifecycleStatusResponse, error) {
	return contracts.LifecycleStatusResponse{Status: u.lifecycle.Status(ctx)}, nil
}
