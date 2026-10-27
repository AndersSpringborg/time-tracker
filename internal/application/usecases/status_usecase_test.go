package usecases_test

import (
	"context"
	"errors"
	"testing"

	"time-tracker/internal/application/usecases"
	"time-tracker/internal/domain"
)

// fakeStatusRepo stands in for the database with real rule and hierarchy data,
// so the use case runs the same matching code the CLI does.
type fakeStatusRepo struct {
	unmapped         int64
	unmappedErr      error
	rules            []domain.Rule
	currentProjectID *int64
	projects         []domain.Project
	activities       []domain.Activity
}

func (f *fakeStatusRepo) UnmappedEventCount(context.Context) (int64, error) {
	return f.unmapped, f.unmappedErr
}
func (f *fakeStatusRepo) ListRules(context.Context) ([]domain.Rule, error) { return f.rules, nil }
func (f *fakeStatusRepo) CurrentProjectID(context.Context) (*int64, error) {
	return f.currentProjectID, nil
}
func (f *fakeStatusRepo) ListAllProjects(context.Context) ([]domain.Project, error) {
	return f.projects, nil
}
func (f *fakeStatusRepo) ListAllActivities(context.Context) ([]domain.Activity, error) {
	return f.activities, nil
}

func repoWithMapping() *fakeStatusRepo {
	return &fakeStatusRepo{
		unmapped: 42,
		rules: []domain.Rule{{
			ID:           1,
			RuleKey:      "ghostty",
			AppPattern:   "Ghostty",
			TitlePattern: "*",
			Priority:     100,
			ProjectID:    ptr(int64(7)),
			ActivityID:   ptr(int64(9)),
			ActionType:   domain.RuleActionAssignExplicit,
		}},
		projects:   []domain.Project{{ProjectID: 7, Title: "Time Tracker"}},
		activities: []domain.Activity{{ActivityID: 9, ProjectID: 7, Title: "Development"}},
	}
}

func ptr[T any](v T) *T { return &v }

func TestStatusReportsTheUnmatchedEventCount(t *testing.T) {
	uc := usecases.NewStatusUsecase(repoWithMapping())

	status, err := uc.Status(context.Background(), domain.WindowSnapshot{})
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if status.UnmatchedCount != 42 {
		t.Fatalf("expected 42 unmatched events, got %d", status.UnmatchedCount)
	}
}

func TestStatusResolvesTheCurrentWindowToProjectAndActivity(t *testing.T) {
	uc := usecases.NewStatusUsecase(repoWithMapping())

	status, err := uc.Status(context.Background(), domain.WindowSnapshot{
		AppName: "Ghostty", WindowTitle: "zig build test",
	})
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if !status.Matched {
		t.Fatal("expected the window to match a rule")
	}
	if status.Project != "Time Tracker" || status.Activity != "Development" {
		t.Fatalf("expected Time Tracker/Development, got %q/%q", status.Project, status.Activity)
	}
}

func TestStatusReportsNoMatchForAWindowNoRuleCovers(t *testing.T) {
	uc := usecases.NewStatusUsecase(repoWithMapping())

	status, err := uc.Status(context.Background(), domain.WindowSnapshot{
		AppName: "Mail", WindowTitle: "Inbox",
	})
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if status.Matched || status.Project != "" || status.Activity != "" {
		t.Fatalf("expected no match, got %+v", status)
	}
	if status.UnmatchedCount != 42 {
		t.Fatalf("the count is independent of matching, got %d", status.UnmatchedCount)
	}
}

func TestStatusWithoutAWindowDoesNotMatch(t *testing.T) {
	uc := usecases.NewStatusUsecase(repoWithMapping())

	status, err := uc.Status(context.Background(), domain.WindowSnapshot{})
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if status.Matched {
		t.Fatal("an empty window cannot match a rule")
	}
}

func TestStatusFailsWhenTheCountIsUnavailable(t *testing.T) {
	repo := repoWithMapping()
	repo.unmappedErr = errors.New("database is busy")
	uc := usecases.NewStatusUsecase(repo)

	if _, err := uc.Status(context.Background(), domain.WindowSnapshot{}); err == nil {
		t.Fatal("expected the failure to surface rather than a zero count")
	}
}

func TestStatusReportsAMatchWhoseTargetNamesAreUnknown(t *testing.T) {
	repo := repoWithMapping()
	repo.projects = nil
	repo.activities = nil
	uc := usecases.NewStatusUsecase(repo)

	status, err := uc.Status(context.Background(), domain.WindowSnapshot{
		AppName: "Ghostty", WindowTitle: "zig build test",
	})
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if !status.Matched {
		t.Fatal("the rule still matched even though its target names are missing")
	}
	if status.Project != "" || status.Activity != "" {
		t.Fatalf("expected empty names, got %q/%q", status.Project, status.Activity)
	}
}
