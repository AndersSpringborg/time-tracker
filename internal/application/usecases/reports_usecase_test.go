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
func (fakeReportsProjectsRepo) ListArchivedProjects(context.Context) ([]domain.Project, error) {
	return nil, nil
}
func (fakeReportsProjectsRepo) CreateProject(context.Context, string, string) (domain.Project, error) {
	return domain.Project{}, nil
}
func (fakeReportsProjectsRepo) ListActivitiesByProject(context.Context, int64) ([]domain.Activity, error) {
	return nil, nil
}
func (fakeReportsProjectsRepo) ListAllActivities(context.Context) ([]domain.Activity, error) {
	return nil, nil
}
func (fakeReportsProjectsRepo) AddActivity(context.Context, int64, string) (domain.Activity, error) {
	return domain.Activity{}, nil
}
func (fakeReportsProjectsRepo) DeleteActivity(context.Context, int64) error { return nil }
func (fakeReportsProjectsRepo) RemoveActivityFromProject(context.Context, int64, int64) error {
	return nil
}
func (fakeReportsProjectsRepo) ActivateProject(context.Context, int64) error { return nil }
func (fakeReportsProjectsRepo) ArchiveProject(context.Context, int64) error  { return nil }
func (fakeReportsProjectsRepo) RestoreProject(context.Context, int64) error  { return nil }
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

type fakeReportsSettingsRepoWithCfg struct {
	cfg domain.Settings
}

func (f fakeReportsSettingsRepoWithCfg) Load(context.Context) (domain.Settings, string, error) {
	return f.cfg, "", nil
}
func (fakeReportsSettingsRepoWithCfg) Save(context.Context, domain.Settings) (string, error) {
	return "", nil
}

func TestReportsUsecaseReportBuildsDetailedMetrics(t *testing.T) {
	projectID := int64(10)
	activityID := int64(100)
	repo := &fakeReportsRepo{
		events: []domain.Event{
			{ID: 1, TimestampMS: 1, DurationMS: 60_000, AppName: "Code", WindowTitle: "main.go", WifiSSID: "Office", ProjectID: &projectID, ActivityID: &activityID, ProjectTitle: "project a"},
			{ID: 2, TimestampMS: 2, DurationMS: 30_000, AppName: "Slack", WindowTitle: "chat", WifiSSID: "Home"},
			{ID: 3, TimestampMS: 3, DurationMS: 15_000, AppName: "Arc", WindowTitle: "daily standup", WifiSSID: "Office"},
		},
	}
	uc := NewReportsUsecase(repo, fakeReportsProjectsRepo{}, fakeReportsSettingsRepoWithCfg{
		cfg: domain.Settings{WorkWifis: []string{"Office"}},
	})

	res, err := uc.Report(context.Background(), contracts.ReportsBuildRequest{RangeKey: "today"})
	if err != nil {
		t.Fatalf("report failed: %v", err)
	}
	report := res.Report
	if report.TotalEvents != 3 {
		t.Fatalf("expected total events 3, got %d", report.TotalEvents)
	}
	if report.WorkEvents != 2 {
		t.Fatalf("expected work events 2, got %d", report.WorkEvents)
	}
	if report.WorkMS != 75_000 {
		t.Fatalf("unexpected work duration %d", report.WorkMS)
	}
	if report.MappedEvents != 1 || report.UnmappedEvents != 1 {
		t.Fatalf("expected mapped/unmapped 1/1, got %d/%d", report.MappedEvents, report.UnmappedEvents)
	}
	if report.MappedMS != 60_000 || report.UnmappedMS != 15_000 {
		t.Fatalf("unexpected mapped/unmapped durations %d/%d", report.MappedMS, report.UnmappedMS)
	}
	if len(report.ByWindow) == 0 {
		t.Fatalf("expected by-window details")
	}
}
