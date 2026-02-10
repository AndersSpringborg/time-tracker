package usecases

import (
	"context"
	"strings"

	"time-tracker/internal/application/contracts"
	"time-tracker/internal/application/ports"
	"time-tracker/internal/domain"
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

func (u *ProjectsUsecase) ListArchived(ctx context.Context, _ contracts.ProjectsListArchivedRequest) (contracts.ProjectsListArchivedResponse, error) {
	projects, err := u.repo.ListArchivedProjects(ctx)
	if err != nil {
		return contracts.ProjectsListArchivedResponse{}, err
	}
	return contracts.ProjectsListArchivedResponse{Projects: projects}, nil
}

func (u *ProjectsUsecase) Create(ctx context.Context, req contracts.ProjectsCreateRequest) (contracts.ProjectsCreateResponse, error) {
	title := strings.TrimSpace(req.Title)
	if title == "" {
		return contracts.ProjectsCreateResponse{}, domain.ErrProjectTitleRequired
	}
	project, err := u.repo.CreateProject(ctx, title, strings.TrimSpace(req.Metadata))
	if err != nil {
		return contracts.ProjectsCreateResponse{}, err
	}
	return contracts.ProjectsCreateResponse{Project: project}, nil
}

func (u *ProjectsUsecase) ListActivitiesByProject(ctx context.Context, req contracts.ProjectsListActivitiesRequest) (contracts.ProjectsListActivitiesResponse, error) {
	activities, err := u.repo.ListActivitiesByProject(ctx, req.ProjectID)
	if err != nil {
		return contracts.ProjectsListActivitiesResponse{}, err
	}
	return contracts.ProjectsListActivitiesResponse{Activities: activities}, nil
}

func (u *ProjectsUsecase) ListAllActivities(ctx context.Context, _ contracts.ProjectsListAllActivitiesRequest) (contracts.ProjectsListAllActivitiesResponse, error) {
	activities, err := u.repo.ListAllActivities(ctx)
	if err != nil {
		return contracts.ProjectsListAllActivitiesResponse{}, err
	}
	return contracts.ProjectsListAllActivitiesResponse{Activities: activities}, nil
}

func (u *ProjectsUsecase) AddActivity(ctx context.Context, req contracts.ProjectsAddActivityRequest) (contracts.ProjectsAddActivityResponse, error) {
	title := strings.TrimSpace(req.Title)
	if title == "" {
		return contracts.ProjectsAddActivityResponse{}, domain.ErrActivityTitleRequired
	}
	activity, err := u.repo.AddActivity(ctx, req.ProjectID, title)
	if err != nil {
		return contracts.ProjectsAddActivityResponse{}, err
	}
	return contracts.ProjectsAddActivityResponse{Activity: activity}, nil
}

func (u *ProjectsUsecase) DeleteActivity(ctx context.Context, req contracts.ProjectsDeleteActivityRequest) (contracts.ProjectsDeleteActivityResponse, error) {
	if err := u.repo.DeleteActivity(ctx, req.ActivityID); err != nil {
		return contracts.ProjectsDeleteActivityResponse{}, err
	}
	return contracts.ProjectsDeleteActivityResponse{}, nil
}

func (u *ProjectsUsecase) RemoveActivityFromProject(ctx context.Context, req contracts.ProjectsRemoveActivityFromProjectRequest) (contracts.ProjectsRemoveActivityFromProjectResponse, error) {
	if err := u.repo.RemoveActivityFromProject(ctx, req.ProjectID, req.ActivityID); err != nil {
		return contracts.ProjectsRemoveActivityFromProjectResponse{}, err
	}
	return contracts.ProjectsRemoveActivityFromProjectResponse{}, nil
}

func (u *ProjectsUsecase) Activate(ctx context.Context, req contracts.ProjectsActivateRequest) (contracts.ProjectsActivateResponse, error) {
	if err := u.repo.ActivateProject(ctx, req.ProjectID); err != nil {
		return contracts.ProjectsActivateResponse{}, err
	}
	return contracts.ProjectsActivateResponse{}, nil
}

func (u *ProjectsUsecase) Archive(ctx context.Context, req contracts.ProjectsArchiveRequest) (contracts.ProjectsArchiveResponse, error) {
	if err := u.repo.ArchiveProject(ctx, req.ProjectID); err != nil {
		return contracts.ProjectsArchiveResponse{}, err
	}
	return contracts.ProjectsArchiveResponse{}, nil
}

func (u *ProjectsUsecase) Restore(ctx context.Context, req contracts.ProjectsRestoreRequest) (contracts.ProjectsRestoreResponse, error) {
	if err := u.repo.RestoreProject(ctx, req.ProjectID); err != nil {
		return contracts.ProjectsRestoreResponse{}, err
	}
	return contracts.ProjectsRestoreResponse{}, nil
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
