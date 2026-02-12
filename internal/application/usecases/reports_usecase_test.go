package usecases

import (
	"context"
	"testing"
	"time"

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
	if len(report.ByWifi) != 1 || report.ByWifi[0].Name != "Office" || report.ByWifi[0].TotalMS != 75_000 {
		t.Fatalf("unexpected wifi summary: %+v", report.ByWifi)
	}
	if len(report.ByWindow) == 0 {
		t.Fatalf("expected by-window details")
	}
	if len(report.MappedDetails) == 0 || len(report.MappedDetails[0].Activities) == 0 || len(report.MappedDetails[0].Activities[0].Events) == 0 {
		t.Fatalf("expected mapped details with events")
	}
	if report.MappedDetails[0].Activities[0].Events[0].WifiSSID != "Office" {
		t.Fatalf("expected mapped event wifi to be preserved, got %q", report.MappedDetails[0].Activities[0].Events[0].WifiSSID)
	}
}

func TestReportsUsecaseReportUsesAllEventsWhenWorkWifiNotConfigured(t *testing.T) {
	projectID := int64(10)
	activityID := int64(100)
	repo := &fakeReportsRepo{
		events: []domain.Event{
			{ID: 1, TimestampMS: 1, DurationMS: 60_000, AppName: "Code", WindowTitle: "main.go", WifiSSID: "Office", ProjectID: &projectID, ActivityID: &activityID, ProjectTitle: "project a"},
			{ID: 2, TimestampMS: 2, DurationMS: 30_000, AppName: "Slack", WindowTitle: "chat", WifiSSID: "Home"},
		},
	}
	uc := NewReportsUsecase(repo, fakeReportsProjectsRepo{}, fakeReportsSettingsRepoWithCfg{
		cfg: domain.Settings{WorkWifis: nil},
	})

	res, err := uc.Report(context.Background(), contracts.ReportsBuildRequest{RangeKey: "today"})
	if err != nil {
		t.Fatalf("report failed: %v", err)
	}
	report := res.Report
	if report.WorkEvents != 2 {
		t.Fatalf("expected work events 2, got %d", report.WorkEvents)
	}
	if report.WorkMS != 90_000 {
		t.Fatalf("expected work duration 90000, got %d", report.WorkMS)
	}
	if len(report.ByWifi) != 2 {
		t.Fatalf("expected wifi summary for both wifi networks, got %+v", report.ByWifi)
	}
	if len(report.ByProject) == 0 || len(report.ByApp) == 0 {
		t.Fatalf("expected populated summaries when work_wifis is empty")
	}
}

func TestNormalizeTimelineHours(t *testing.T) {
	startHour, endHour := NormalizeTimelineHours(-1, 30)
	if startHour != 8 || endHour != 17 {
		t.Fatalf("expected defaults 8-17, got %d-%d", startHour, endHour)
	}
	startHour, endHour = NormalizeTimelineHours(9, 18)
	if startHour != 9 || endHour != 18 {
		t.Fatalf("expected valid range 9-18, got %d-%d", startHour, endHour)
	}
	startHour, endHour = NormalizeTimelineHours(18, 9)
	if startHour != 8 || endHour != 17 {
		t.Fatalf("expected invalid range to fall back to defaults, got %d-%d", startHour, endHour)
	}
}

func TestReportsUsecaseTimelineBuildsDayView(t *testing.T) {
	day := time.Date(2026, time.February, 7, 0, 0, 0, 0, time.Local)
	projectID := int64(10)
	activityID := int64(100)
	repo := &fakeReportsRepo{
		events: []domain.Event{
			{
				ID:           1,
				TimestampMS:  day.Add(8*time.Hour + 30*time.Minute).UnixMilli(),
				DurationMS:   30 * 60 * 1000,
				AppName:      "Code",
				WindowTitle:  "main.go",
				WifiSSID:     "Office",
				ProjectID:    &projectID,
				ActivityID:   &activityID,
				ProjectTitle: "project a",
				ActivityName: "development",
			},
			{
				ID:          3,
				TimestampMS: day.Add(10 * time.Hour).UnixMilli(),
				DurationMS:  60 * 1000,
				AppName:     "Code",
				WindowTitle: "tiny.go",
				WifiSSID:    "Office",
			},
			{
				ID:          2,
				TimestampMS: day.Add(18 * time.Hour).UnixMilli(),
				DurationMS:  15 * 60 * 1000,
				AppName:     "Arc",
				WindowTitle: "daily",
				WifiSSID:    "",
			},
		},
	}
	uc := NewReportsUsecase(repo, fakeReportsProjectsRepo{}, fakeReportsSettingsRepo{})
	date := "2026-02-07"

	res, err := uc.Timeline(context.Background(), contracts.ReportsTimelineRequest{
		Date:      &date,
		StartHour: 8,
		EndHour:   17,
	})
	if err != nil {
		t.Fatalf("timeline failed: %v", err)
	}
	if repo.lastRangeKey != "all" {
		t.Fatalf("expected timeline to use all range with date filter, got %s", repo.lastRangeKey)
	}
	if repo.lastDate == nil || *repo.lastDate != date {
		t.Fatalf("expected timeline date forwarding, got %+v", repo.lastDate)
	}
	timeline := res.Timeline
	if timeline.StartHour != 8 || timeline.EndHour != 17 {
		t.Fatalf("expected timeline range 8-17, got %d-%d", timeline.StartHour, timeline.EndHour)
	}
	if timeline.TotalEvents != 3 || timeline.VisibleEvents != 2 {
		t.Fatalf("unexpected timeline event counts %+v", timeline)
	}
	if len(timeline.Events) != 3 {
		t.Fatalf("expected 3 timeline events, got %d", len(timeline.Events))
	}
	if !timeline.Events[0].InView {
		t.Fatalf("expected first event in view")
	}
	if !timeline.Events[1].InView {
		t.Fatalf("expected second event in view")
	}
	if timeline.Events[1].HeightPercent >= 0.7 {
		t.Fatalf("expected tiny event height to stay proportional, got %.4f", timeline.Events[1].HeightPercent)
	}
	if timeline.Events[2].InView {
		t.Fatalf("expected third event outside view")
	}
	if timeline.Events[2].WifiSSID != "(none)" {
		t.Fatalf("expected empty wifi to render as (none), got %q", timeline.Events[2].WifiSSID)
	}
}
