package usecases

import (
	"context"

	"time-tracker/internal/application/ports"
	"time-tracker/internal/domain"
)

type ProjectsUsecase struct{ repo ports.ProjectsRepository }

func NewProjectsUsecase(repo ports.ProjectsRepository) *ProjectsUsecase {
	return &ProjectsUsecase{repo: repo}
}

func (u *ProjectsUsecase) ListActive(ctx context.Context) ([]domain.Project, error) {
	return u.repo.ListActiveProjects(ctx)
}
func (u *ProjectsUsecase) ListAll(ctx context.Context) ([]domain.Project, error) {
	return u.repo.ListAllProjects(ctx)
}
func (u *ProjectsUsecase) Activate(ctx context.Context, id int64) error {
	return u.repo.ActivateProject(ctx, id)
}
func (u *ProjectsUsecase) End(ctx context.Context, id int64) error { return u.repo.EndProject(ctx, id) }
func (u *ProjectsUsecase) EndAll(ctx context.Context) error        { return u.repo.EndAllProjects(ctx) }
func (u *ProjectsUsecase) Current(ctx context.Context) (string, *int64, error) {
	return u.repo.CurrentProject(ctx)
}
