package usecases

import (
	"context"

	"time-tracker/internal/application/ports"
	"time-tracker/internal/domain"
)

type LifecycleUsecase struct{ lifecycle ports.LifecyclePort }

func NewLifecycleUsecase(l ports.LifecyclePort) *LifecycleUsecase {
	return &LifecycleUsecase{lifecycle: l}
}

func (u *LifecycleUsecase) Install(ctx context.Context) error   { return u.lifecycle.Install(ctx) }
func (u *LifecycleUsecase) Uninstall(ctx context.Context) error { return u.lifecycle.Uninstall(ctx) }
func (u *LifecycleUsecase) Start(ctx context.Context) error     { return u.lifecycle.Start(ctx) }
func (u *LifecycleUsecase) Stop(ctx context.Context) error      { return u.lifecycle.Stop(ctx) }
func (u *LifecycleUsecase) Status(ctx context.Context) domain.LifecycleStatus {
	return u.lifecycle.Status(ctx)
}
