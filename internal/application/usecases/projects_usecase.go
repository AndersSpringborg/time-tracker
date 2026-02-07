package usecases

import (
	"context"

	"time-tracker/internal/application/contracts"
	"time-tracker/internal/application/ports"
)

type ProjectsUsecase struct{ repo ports.ProjectsRepository }

func NewProjectsUsecase(repo ports.ProjectsRepository) *ProjectsUsecase {
	return &ProjectsUsecase{repo: repo}
}

func (u *ProjectsUsecase) ListActive(ctx context.Context, _ contracts.ProjectsListActiveRequest) (contracts.ProjectsListActiveResponse, error) {
	projects, err := u.repo.ListActiveProjects(ctx)
	if err != nil {
		return contracts.ProjectsListActiveResponse{}, err
	}
	return contracts.ProjectsListActiveResponse{Projects: projects}, nil
}
func (u *ProjectsUsecase) ListAll(ctx context.Context, _ contracts.ProjectsListAllRequest) (contracts.ProjectsListAllResponse, error) {
	projects, err := u.repo.ListAllProjects(ctx)
	if err != nil {
		return contracts.ProjectsListAllResponse{}, err
	}
	return contracts.ProjectsListAllResponse{Projects: projects}, nil
}
func (u *ProjectsUsecase) Activate(ctx context.Context, req contracts.ProjectsActivateRequest) (contracts.ProjectsActivateResponse, error) {
	if err := u.repo.ActivateProject(ctx, req.ProjectID); err != nil {
		return contracts.ProjectsActivateResponse{}, err
	}
	return contracts.ProjectsActivateResponse{}, nil
}
func (u *ProjectsUsecase) End(ctx context.Context, req contracts.ProjectsEndRequest) (contracts.ProjectsEndResponse, error) {
	if err := u.repo.EndProject(ctx, req.ProjectID); err != nil {
		return contracts.ProjectsEndResponse{}, err
	}
	return contracts.ProjectsEndResponse{}, nil
}

func (u *ProjectsUsecase) EndAll(ctx context.Context, _ contracts.ProjectsEndAllRequest) (contracts.ProjectsEndAllResponse, error) {
	if err := u.repo.EndAllProjects(ctx); err != nil {
		return contracts.ProjectsEndAllResponse{}, err
	}
	return contracts.ProjectsEndAllResponse{}, nil
}

func (u *ProjectsUsecase) Current(ctx context.Context, _ contracts.ProjectsCurrentRequest) (contracts.ProjectsCurrentResponse, error) {
	name, id, err := u.repo.CurrentProject(ctx)
	if err != nil {
		return contracts.ProjectsCurrentResponse{}, err
	}
	return contracts.ProjectsCurrentResponse{Name: name, ProjectID: id}, nil
}
