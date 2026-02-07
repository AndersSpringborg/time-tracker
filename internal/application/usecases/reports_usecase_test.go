package usecases

import (
	"context"
	"testing"

	"time-tracker/internal/application/contracts"
	"time-tracker/internal/domain"
)

type fakeReportsRepo struct {
	events       []domain.Event
	lastRangeKey string
	lastDate     *string
}

func (f *fakeReportsRepo) ListReportEvents(_ context.Context, rangeKey string, date *string) ([]domain.Event, error) {
	f.lastRangeKey = rangeKey
	f.lastDate = date
	return f.events, nil
}

type fakeReportsProjectsRepo struct{}

func (fakeReportsProjectsRepo) ListActiveProjects(context.Context) ([]domain.Project, error) {
	return nil, nil
}
func (fakeReportsProjectsRepo) ListAllProjects(context.Context) ([]domain.Project, error) {
	return nil, nil
}
func (fakeReportsProjectsRepo) ActivateProject(context.Context, int64) error { return nil }
func (fakeReportsProjectsRepo) EndProject(context.Context, int64) error      { return nil }
func (fakeReportsProjectsRepo) EndAllProjects(context.Context) error         { return nil }
func (fakeReportsProjectsRepo) CurrentProject(context.Context) (string, *int64, error) {
	return "", nil, nil
}

type fakeReportsSettingsRepo struct{}

func (fakeReportsSettingsRepo) Load(context.Context) (domain.Settings, string, error) {
	return domain.Settings{}, "", nil
}
func (fakeReportsSettingsRepo) Save(context.Context, domain.Settings) (string, error) {
	return "", nil
}

func TestNormalizeReportDate(t *testing.T) {
	got := NormalizeReportDate(" 2026-02-07 ")
	if got == nil || *got != "2026-02-07" {
		t.Fatalf("expected normalized report date, got %+v", got)
	}
	if NormalizeReportDate("invalid") != nil {
		t.Fatalf("expected invalid date to return nil")
	}
}

func TestPreviousDate(t *testing.T) {
	if got := PreviousDate("2026-02-07"); got != "2026-02-06" {
		t.Fatalf("expected previous date 2026-02-06, got %s", got)
	}
}

func TestReportsUsecaseReportUsesNormalizedDate(t *testing.T) {
	repo := &fakeReportsRepo{}
	uc := NewReportsUsecase(repo, fakeReportsProjectsRepo{}, fakeReportsSettingsRepo{})
	date := "2026-02-07"

	if _, err := uc.Report(context.Background(), contracts.ReportsBuildRequest{
		RangeKey: "week",
		Date:     &date,
	}); err != nil {
		t.Fatalf("report failed: %v", err)
	}

	if repo.lastRangeKey != "week" {
		t.Fatalf("expected range key week, got %s", repo.lastRangeKey)
	}
	if repo.lastDate == nil || *repo.lastDate != "2026-02-07" {
		t.Fatalf("expected normalized date to be forwarded, got %+v", repo.lastDate)
	}
}

func TestReportsUsecaseReportIgnoresInvalidDate(t *testing.T) {
	repo := &fakeReportsRepo{}
	uc := NewReportsUsecase(repo, fakeReportsProjectsRepo{}, fakeReportsSettingsRepo{})
	date := "not-a-date"

	if _, err := uc.Report(context.Background(), contracts.ReportsBuildRequest{
		RangeKey: "all",
		Date:     &date,
	}); err != nil {
		t.Fatalf("report failed: %v", err)
	}

	if repo.lastDate != nil {
		t.Fatalf("expected invalid date to be dropped, got %+v", repo.lastDate)
	}
}

func TestReportsUsecaseReportNormalizesInvalidRange(t *testing.T) {
	repo := &fakeReportsRepo{}
	uc := NewReportsUsecase(repo, fakeReportsProjectsRepo{}, fakeReportsSettingsRepo{})

	if _, err := uc.Report(context.Background(), contracts.ReportsBuildRequest{
		RangeKey: "unknown",
	}); err != nil {
		t.Fatalf("report failed: %v", err)
	}

	if repo.lastRangeKey != "today" {
		t.Fatalf("expected invalid range to normalize to today, got %s", repo.lastRangeKey)
	}
}
