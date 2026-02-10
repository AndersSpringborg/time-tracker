package usecases

import (
	"context"
	"strings"
	"testing"

	"time-tracker/internal/application/contracts"
	"time-tracker/internal/domain"
)

type fakeProjectsRepo struct {
	projects    []domain.Project
	archived    []domain.Project
	activities  []domain.Activity
	nextProjID  int64
	nextActID   int64
	inUseByAct  map[int64]bool
	activeCalls []int64
}

func newFakeProjectsRepo() *fakeProjectsRepo {
	return &fakeProjectsRepo{
		nextProjID: 1,
		nextActID:  1,
		inUseByAct: map[int64]bool{},
	}
}

func (f *fakeProjectsRepo) ListActiveProjects(context.Context) ([]domain.Project, error) {
	out := make([]domain.Project, 0, len(f.activeCalls))
	for _, id := range f.activeCalls {
		for _, project := range f.projects {
			if project.ProjectID == id {
				out = append(out, project)
			}
		}
	}
	return out, nil
}

func (f *fakeProjectsRepo) ListAllProjects(context.Context) ([]domain.Project, error) {
	out := make([]domain.Project, len(f.projects))
	copy(out, f.projects)
	return out, nil
}

func (f *fakeProjectsRepo) ListArchivedProjects(context.Context) ([]domain.Project, error) {
	out := make([]domain.Project, len(f.archived))
	copy(out, f.archived)
	return out, nil
}

func (f *fakeProjectsRepo) CreateProject(_ context.Context, title, metadata string) (domain.Project, error) {
	for _, project := range f.projects {
		if strings.EqualFold(strings.TrimSpace(project.Title), strings.TrimSpace(title)) {
			return domain.Project{}, domain.ErrProjectTitleConflict
		}
	}
	for _, project := range f.archived {
		if strings.EqualFold(strings.TrimSpace(project.Title), strings.TrimSpace(title)) {
			return domain.Project{}, domain.ErrProjectTitleConflict
		}
	}
	project := domain.Project{
		ProjectID: f.nextProjID,
		Title:     title,
		Metadata:  metadata,
	}
	f.nextProjID++
	f.projects = append(f.projects, project)
	return project, nil
}

func (f *fakeProjectsRepo) ListActivitiesByProject(_ context.Context, projectID int64) ([]domain.Activity, error) {
	out := make([]domain.Activity, 0)
	for _, activity := range f.activities {
		if activity.ProjectID == projectID {
			out = append(out, activity)
		}
	}
	return out, nil
}

func (f *fakeProjectsRepo) ListAllActivities(context.Context) ([]domain.Activity, error) {
	out := make([]domain.Activity, len(f.activities))
	copy(out, f.activities)
	return out, nil
}

func (f *fakeProjectsRepo) AddActivity(_ context.Context, projectID int64, title string) (domain.Activity, error) {
	projectExists := false
	for _, project := range f.projects {
		if project.ProjectID == projectID {
			projectExists = true
			break
		}
	}
	if !projectExists {
		return domain.Activity{}, domain.ErrProjectNotFound
	}
	for _, activity := range f.activities {
		if activity.ProjectID == projectID && strings.EqualFold(strings.TrimSpace(activity.Title), strings.TrimSpace(title)) {
			return domain.Activity{}, domain.ErrActivityTitleConflict
		}
	}
	activity := domain.Activity{
		ActivityID: f.nextActID,
		ProjectID:  projectID,
		Title:      title,
	}
	f.nextActID++
	f.activities = append(f.activities, activity)
	return activity, nil
}

func (f *fakeProjectsRepo) DeleteActivity(_ context.Context, activityID int64) error {
	if f.inUseByAct[activityID] {
		return domain.ErrActivityInUse
	}
	for i, activity := range f.activities {
		if activity.ActivityID == activityID {
			f.activities = append(f.activities[:i], f.activities[i+1:]...)
			return nil
		}
	}
	return domain.ErrActivityNotFound
}

func (f *fakeProjectsRepo) RemoveActivityFromProject(_ context.Context, projectID, activityID int64) error {
	if f.inUseByAct[activityID] {
		return domain.ErrActivityInUse
	}
	for i, activity := range f.activities {
		if activity.ActivityID == activityID && activity.ProjectID == projectID {
			f.activities = append(f.activities[:i], f.activities[i+1:]...)
			return nil
		}
	}
	return domain.ErrActivityNotFound
}

func (f *fakeProjectsRepo) ActivateProject(_ context.Context, projectID int64) error {
	f.activeCalls = append(f.activeCalls, projectID)
	return nil
}

func (f *fakeProjectsRepo) ArchiveProject(_ context.Context, projectID int64) error {
	for i, project := range f.projects {
		if project.ProjectID == projectID {
			f.projects = append(f.projects[:i], f.projects[i+1:]...)
			f.archived = append(f.archived, project)
			return nil
		}
	}
	return domain.ErrProjectNotFound
}

func (f *fakeProjectsRepo) RestoreProject(_ context.Context, projectID int64) error {
	for i, project := range f.archived {
		if project.ProjectID == projectID {
			f.archived = append(f.archived[:i], f.archived[i+1:]...)
			f.projects = append(f.projects, project)
			return nil
		}
	}
	return domain.ErrProjectNotFound
}

func (f *fakeProjectsRepo) EndProject(context.Context, int64) error { return nil }
func (f *fakeProjectsRepo) EndAllProjects(context.Context) error    { return nil }
func (f *fakeProjectsRepo) CurrentProject(context.Context) (string, *int64, error) {
	return "None", nil, nil
}

func TestProjectsUsecaseCreateRejectsEmptyTitle(t *testing.T) {
	repo := newFakeProjectsRepo()
	uc := NewProjectsUsecase(repo)

	_, err := uc.Create(context.Background(), contracts.ProjectsCreateRequest{Title: "   "})
	if err == nil {
		t.Fatalf("expected error for empty title")
	}
	if err != domain.ErrProjectTitleRequired {
		t.Fatalf("expected ErrProjectTitleRequired, got %v", err)
	}
}

func TestProjectsUsecaseCreateTrimsInput(t *testing.T) {
	repo := newFakeProjectsRepo()
	uc := NewProjectsUsecase(repo)

	res, err := uc.Create(context.Background(), contracts.ProjectsCreateRequest{
		Title:    "  Portal  ",
		Metadata: "  customer work  ",
	})
	if err != nil {
		t.Fatalf("create project failed: %v", err)
	}
	if res.Project.Title != "Portal" {
		t.Fatalf("expected trimmed title, got %q", res.Project.Title)
	}
	if res.Project.Metadata != "customer work" {
		t.Fatalf("expected trimmed metadata, got %q", res.Project.Metadata)
	}
}

func TestProjectsUsecaseAddActivityRejectsEmptyTitle(t *testing.T) {
	repo := newFakeProjectsRepo()
	repo.projects = append(repo.projects, domain.Project{ProjectID: 1, Title: "Portal"})
	uc := NewProjectsUsecase(repo)

	_, err := uc.AddActivity(context.Background(), contracts.ProjectsAddActivityRequest{
		ProjectID: 1,
		Title:     "  ",
	})
	if err == nil {
		t.Fatalf("expected error for empty activity title")
	}
	if err != domain.ErrActivityTitleRequired {
		t.Fatalf("expected ErrActivityTitleRequired, got %v", err)
	}
}

func TestProjectsUsecaseAddActivityRejectsDuplicateInProject(t *testing.T) {
	repo := newFakeProjectsRepo()
	repo.projects = append(repo.projects, domain.Project{ProjectID: 1, Title: "Portal"})
	uc := NewProjectsUsecase(repo)

	if _, err := uc.AddActivity(context.Background(), contracts.ProjectsAddActivityRequest{
		ProjectID: 1,
		Title:     "Development",
	}); err != nil {
		t.Fatalf("first add activity failed: %v", err)
	}
	_, err := uc.AddActivity(context.Background(), contracts.ProjectsAddActivityRequest{
		ProjectID: 1,
		Title:     " development ",
	})
	if err == nil {
		t.Fatalf("expected duplicate activity error")
	}
	if err != domain.ErrActivityTitleConflict {
		t.Fatalf("expected ErrActivityTitleConflict, got %v", err)
	}
}

func TestProjectsUsecaseArchiveAndRestore(t *testing.T) {
	repo := newFakeProjectsRepo()
	repo.projects = append(repo.projects, domain.Project{ProjectID: 1, Title: "Portal"})
	uc := NewProjectsUsecase(repo)

	if _, err := uc.Archive(context.Background(), contracts.ProjectsArchiveRequest{ProjectID: 1}); err != nil {
		t.Fatalf("archive failed: %v", err)
	}
	if len(repo.projects) != 0 || len(repo.archived) != 1 {
		t.Fatalf("expected project moved to archived lists")
	}
	if _, err := uc.Restore(context.Background(), contracts.ProjectsRestoreRequest{ProjectID: 1}); err != nil {
		t.Fatalf("restore failed: %v", err)
	}
	if len(repo.projects) != 1 || len(repo.archived) != 0 {
		t.Fatalf("expected project restored to active list")
	}
}

func TestProjectsUsecaseDeleteActivityReturnsInUseError(t *testing.T) {
	repo := newFakeProjectsRepo()
	repo.projects = append(repo.projects, domain.Project{ProjectID: 1, Title: "Portal"})
	repo.activities = append(repo.activities, domain.Activity{ActivityID: 3, ProjectID: 1, Title: "Meeting"})
	repo.inUseByAct[3] = true
	uc := NewProjectsUsecase(repo)

	_, err := uc.DeleteActivity(context.Background(), contracts.ProjectsDeleteActivityRequest{ActivityID: 3})
	if err == nil {
		t.Fatalf("expected delete error for in-use activity")
	}
	if err != domain.ErrActivityInUse {
		t.Fatalf("expected ErrActivityInUse, got %v", err)
	}
}
