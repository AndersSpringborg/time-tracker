package usecases

import (
	"context"
	"errors"
	"testing"

	"time-tracker/internal/domain"
)

type fakeTidsregGateway struct {
	authCookie string
	authErr    error

	customers  []domain.TidsregCustomer
	projects   map[int64][]domain.TidsregProject
	phases     map[int64][]domain.TidsregPhase
	activities map[int64][]domain.TidsregActivity
}

func (f *fakeTidsregGateway) Authenticate(context.Context, string, string) (string, error) {
	if f.authErr != nil {
		return "", f.authErr
	}
	if f.authCookie == "" {
		return "cookie=ok", nil
	}
	return f.authCookie, nil
}

func (f *fakeTidsregGateway) ListCustomers(context.Context, string, domain.TidsregMode) ([]domain.TidsregCustomer, error) {
	return f.customers, nil
}

func (f *fakeTidsregGateway) ListProjects(_ context.Context, _ string, customerID int64, _ domain.TidsregMode) ([]domain.TidsregProject, error) {
	return f.projects[customerID], nil
}

func (f *fakeTidsregGateway) ListPhases(_ context.Context, _ string, projectID int64, _ domain.TidsregMode) ([]domain.TidsregPhase, error) {
	return f.phases[projectID], nil
}

func (f *fakeTidsregGateway) ListActivities(_ context.Context, _ string, phaseID int64, _ domain.TidsregMode) ([]domain.TidsregActivity, error) {
	return f.activities[phaseID], nil
}

type fakeTidsregImportRepo struct {
	upserts []domain.ImportedProjectUpsert
	syncs   map[int64][]domain.ImportedActivityUpsert
}

func (f *fakeTidsregImportRepo) UpsertImportedProject(_ context.Context, in domain.ImportedProjectUpsert) (domain.ImportedProjectUpsertResult, error) {
	f.upserts = append(f.upserts, in)
	return domain.ImportedProjectUpsertResult{ProjectID: int64(100 + len(f.upserts)), Created: true, Updated: false}, nil
}

func (f *fakeTidsregImportRepo) SyncImportedActivities(_ context.Context, projectID int64, activities []domain.ImportedActivityUpsert) (domain.ImportedActivitySyncResult, error) {
	if f.syncs == nil {
		f.syncs = map[int64][]domain.ImportedActivityUpsert{}
	}
	f.syncs[projectID] = append([]domain.ImportedActivityUpsert(nil), activities...)
	return domain.ImportedActivitySyncResult{Created: len(activities)}, nil
}

func TestTidsregImportUsecaseBuildsPreview(t *testing.T) {
	gateway := &fakeTidsregGateway{
		customers: []domain.TidsregCustomer{{CustomerID: 1, Name: "Trifork"}},
		projects: map[int64][]domain.TidsregProject{
			1: {{ProjectID: 10, CustomerID: 1, Name: "Portal"}},
		},
		phases: map[int64][]domain.TidsregPhase{
			10: {{PhaseID: 100, ProjectID: 10, Name: "Development"}},
		},
		activities: map[int64][]domain.TidsregActivity{
			100: {{ActivityID: 1000, PhaseID: 100, Name: "Coding"}},
		},
	}
	uc := NewTidsregImportUsecase(gateway, &fakeTidsregImportRepo{})

	preview, err := uc.BuildPreview(context.Background(), "session=ok", domain.TidsregModeTime, gateway.customers, []int64{1})
	if err != nil {
		t.Fatalf("BuildPreview failed: %v", err)
	}
	if len(preview.Candidates) != 1 {
		t.Fatalf("expected 1 candidate, got %d", len(preview.Candidates))
	}
	if preview.Candidates[0].TargetTitle != "Trifork > Portal > Development" {
		t.Fatalf("unexpected title: %s", preview.Candidates[0].TargetTitle)
	}
	if len(preview.Candidates[0].Activities) != 1 {
		t.Fatalf("expected one activity")
	}
}

func TestTidsregImportUsecaseCommitPersistsSelectedCandidates(t *testing.T) {
	repo := &fakeTidsregImportRepo{}
	uc := NewTidsregImportUsecase(&fakeTidsregGateway{}, repo)
	preview := domain.TidsregImportPreview{Candidates: []domain.TidsregImportCandidate{
		{
			Key:          "1:10:100",
			CustomerID:   1,
			ProjectID:    10,
			PhaseID:      100,
			TargetTitle:  "A > B > C",
			Activities:   []domain.TidsregActivity{{ActivityID: 1000, Name: "Coding"}},
			CustomerName: "A",
			ProjectName:  "B",
			PhaseName:    "C",
		},
	}}

	result, err := uc.Commit(context.Background(), preview, []string{"1:10:100"})
	if err != nil {
		t.Fatalf("Commit failed: %v", err)
	}
	if result.ImportedCandidates != 1 {
		t.Fatalf("expected 1 imported candidate, got %d", result.ImportedCandidates)
	}
	if result.ProjectsCreated != 1 {
		t.Fatalf("expected 1 project created, got %d", result.ProjectsCreated)
	}
	if result.ActivitiesCreated != 1 {
		t.Fatalf("expected 1 activity created, got %d", result.ActivitiesCreated)
	}
	if len(repo.upserts) != 1 {
		t.Fatalf("expected one upsert call")
	}
}

func TestTidsregImportUsecaseAuthenticateValidation(t *testing.T) {
	uc := NewTidsregImportUsecase(&fakeTidsregGateway{authErr: errors.New("bad creds")}, &fakeTidsregImportRepo{})
	if _, _, err := uc.AuthenticateAndListCustomers(context.Background(), "", "", domain.TidsregModeTime); err == nil {
		t.Fatalf("expected validation error")
	}
	if _, _, err := uc.AuthenticateAndListCustomers(context.Background(), "u", "p", domain.TidsregModeTime); err == nil {
		t.Fatalf("expected auth error")
	}
}
