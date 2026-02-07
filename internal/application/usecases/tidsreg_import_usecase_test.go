package usecases

import (
	"context"
	"errors"
	"testing"

	"time-tracker/internal/application/contracts"
	tidsregmodel "time-tracker/internal/application/integrations/tidsreg"
	"time-tracker/internal/domain"
)

type fakeTidsregGateway struct {
	authCookie string
	authErr    error

	customers  []tidsregmodel.Customer
	projects   map[int64][]tidsregmodel.Project
	phases     map[int64][]tidsregmodel.Phase
	activities map[int64][]tidsregmodel.Activity
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

func (f *fakeTidsregGateway) ListCustomers(context.Context, string, tidsregmodel.Mode) ([]tidsregmodel.Customer, error) {
	return f.customers, nil
}

func (f *fakeTidsregGateway) ListProjects(_ context.Context, _ string, customerID int64, _ tidsregmodel.Mode) ([]tidsregmodel.Project, error) {
	return f.projects[customerID], nil
}

func (f *fakeTidsregGateway) ListPhases(_ context.Context, _ string, projectID int64, _ tidsregmodel.Mode) ([]tidsregmodel.Phase, error) {
	return f.phases[projectID], nil
}

func (f *fakeTidsregGateway) ListActivities(_ context.Context, _ string, phaseID int64, _ tidsregmodel.Mode) ([]tidsregmodel.Activity, error) {
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
		customers: []tidsregmodel.Customer{{CustomerID: 1, Name: "Trifork"}},
		projects: map[int64][]tidsregmodel.Project{
			1: {{ProjectID: 10, CustomerID: 1, Name: "Portal"}},
		},
		phases: map[int64][]tidsregmodel.Phase{
			10: {{PhaseID: 100, ProjectID: 10, Name: "Development"}},
		},
		activities: map[int64][]tidsregmodel.Activity{
			100: {{ActivityID: 1000, PhaseID: 100, Name: "Coding"}},
		},
	}
	uc := NewTidsregImportUsecase(gateway, &fakeTidsregImportRepo{})

	previewRes, err := uc.BuildPreview(context.Background(), contracts.TidsregBuildPreviewRequest{
		SessionCookie:       "session=ok",
		Mode:                tidsregmodel.ModeTime,
		Customers:           gateway.customers,
		SelectedCustomerIDs: []int64{1},
	})
	if err != nil {
		t.Fatalf("BuildPreview failed: %v", err)
	}
	preview := previewRes.Preview
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
	preview := tidsregmodel.ImportPreview{Candidates: []tidsregmodel.ImportCandidate{
		{
			Key:          "1:10:100",
			CustomerID:   1,
			ProjectID:    10,
			PhaseID:      100,
			TargetTitle:  "A > B > C",
			Activities:   []tidsregmodel.Activity{{ActivityID: 1000, Name: "Coding"}},
			CustomerName: "A",
			ProjectName:  "B",
			PhaseName:    "C",
		},
	}}

	result, err := uc.Commit(context.Background(), contracts.TidsregCommitRequest{
		Preview:      preview,
		SelectedKeys: []string{"1:10:100"},
	})
	if err != nil {
		t.Fatalf("Commit failed: %v", err)
	}
	if result.Result.ImportedCandidates != 1 {
		t.Fatalf("expected 1 imported candidate, got %d", result.Result.ImportedCandidates)
	}
	if result.Result.ProjectsCreated != 1 {
		t.Fatalf("expected 1 project created, got %d", result.Result.ProjectsCreated)
	}
	if result.Result.ActivitiesCreated != 1 {
		t.Fatalf("expected 1 activity created, got %d", result.Result.ActivitiesCreated)
	}
	if len(repo.upserts) != 1 {
		t.Fatalf("expected one upsert call")
	}
}

func TestTidsregImportUsecaseAuthenticateValidation(t *testing.T) {
	uc := NewTidsregImportUsecase(&fakeTidsregGateway{authErr: errors.New("bad creds")}, &fakeTidsregImportRepo{})
	if _, err := uc.AuthenticateAndListCustomers(context.Background(), contracts.TidsregAuthenticateRequest{
		Username: "",
		Password: "",
		Mode:     tidsregmodel.ModeTime,
	}); err == nil {
		t.Fatalf("expected validation error")
	}
	if _, err := uc.AuthenticateAndListCustomers(context.Background(), contracts.TidsregAuthenticateRequest{
		Username: "u",
		Password: "p",
		Mode:     tidsregmodel.ModeTime,
	}); err == nil {
		t.Fatalf("expected auth error")
	}
}
