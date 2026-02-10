package usecases

import (
	"context"
	"sort"
	"strings"
	"time"

	"time-tracker/internal/application/contracts"
	"time-tracker/internal/application/ports"
	"time-tracker/internal/domain"
)

type ReportsUsecase struct {
	reportsRepo  ports.ReportsRepository
	projectsRepo ports.ProjectsRepository
	settingsRepo ports.SettingsRepository
}

func NewReportsUsecase(reportsRepo ports.ReportsRepository, projectsRepo ports.ProjectsRepository, settingsRepo ports.SettingsRepository) *ReportsUsecase {
	return &ReportsUsecase{reportsRepo: reportsRepo, projectsRepo: projectsRepo, settingsRepo: settingsRepo}
}

func (u *ReportsUsecase) Dashboard(ctx context.Context, _ contracts.ReportsDashboardRequest) (contracts.ReportsDashboardResponse, error) {
	cfg, _, err := u.settingsRepo.Load(ctx)
	if err != nil {
		return contracts.ReportsDashboardResponse{}, err
	}
	curName, curID, err := u.projectsRepo.CurrentProject(ctx)
	if err != nil {
		return contracts.ReportsDashboardResponse{}, err
	}
	items, err := u.reportsRepo.ListReportEvents(ctx, "today", nil)
	if err != nil {
		return contracts.ReportsDashboardResponse{}, err
	}
	mask := domain.BuildNoiseMask(items, cfg.NoiseAppPatterns, cfg.NoiseBucketMinutes, cfg.NoiseSwitchMinutes)

	out := domain.Dashboard{CurrentProject: curName, CurrentProjectID: curID}
	for i, e := range items {
		if e.DurationMS <= 0 {
			continue
		}
		out.TrackedEvents++
		if mask[i] {
			out.ExcludedEvents++
			continue
		}
		out.TodayTotalMS += e.DurationMS
	}
	out.TopApps = summarize(items, mask, func(e domain.Event) string { return e.AppName })
	if len(out.TopApps) > 8 {
		out.TopApps = out.TopApps[:8]
	}
	return contracts.ReportsDashboardResponse{Dashboard: out}, nil
}

func (u *ReportsUsecase) Report(ctx context.Context, req contracts.ReportsBuildRequest) (contracts.ReportsBuildResponse, error) {
	cfg, _, err := u.settingsRepo.Load(ctx)
	if err != nil {
		return contracts.ReportsBuildResponse{}, err
	}
	rangeKey := NormalizeRange(req.RangeKey)
	reportDate := NormalizeReportDate(valueOrEmpty(req.Date))
	items, err := u.reportsRepo.ListReportEvents(ctx, rangeKey, reportDate)
	if err != nil {
		return contracts.ReportsBuildResponse{}, err
	}
	mask := domain.BuildNoiseMask(items, cfg.NoiseAppPatterns, cfg.NoiseBucketMinutes, cfg.NoiseSwitchMinutes)

	out := domain.Report{Range: rangeKey}
	for i, e := range items {
		if e.DurationMS <= 0 {
			continue
		}
		out.TotalEvents++
		if mask[i] {
			out.ExcludedEvents++
			continue
		}
		out.IncludedEvents++
		out.TotalMS += e.DurationMS
		if e.ProjectID != nil && e.ActivityID != nil {
			out.MappedEvents++
			out.MappedMS += e.DurationMS
		} else {
			out.UnmappedEvents++
			out.UnmappedMS += e.DurationMS
		}
	}
	out.ByProject = summarize(items, mask, func(e domain.Event) string {
		if strings.TrimSpace(e.ProjectTitle) == "" {
			return "Unmapped"
		}
		return e.ProjectTitle
	})
	out.ByActivity = summarize(items, mask, func(e domain.Event) string {
		if strings.TrimSpace(e.ActivityName) == "" {
			return "Unmapped"
		}
		return e.ActivityName
	})
	out.ByApp = summarize(items, mask, func(e domain.Event) string { return e.AppName })
	out.ByWindow = summarize(items, mask, func(e domain.Event) string {
		app := strings.TrimSpace(e.AppName)
		if app == "" {
			app = "Unknown App"
		}
		title := shortenTitle(strings.TrimSpace(e.WindowTitle), 80)
		if title == "" {
			title = "(empty title)"
		}
		return app + " | " + title
	})
	if len(out.ByWindow) > 12 {
		out.ByWindow = out.ByWindow[:12]
	}

	// Build mapped details: project -> activity -> events
	out.MappedDetails = buildMappedDetails(items, mask)

	return contracts.ReportsBuildResponse{Report: out}, nil
}

func shortenTitle(s string, max int) string {
	if max <= 0 {
		return ""
	}
	runes := []rune(s)
	if len(runes) <= max {
		return s
	}
	if max <= 3 {
		return string(runes[:max])
	}
	return string(runes[:max-3]) + "..."
}

func summarize(events []domain.Event, excluded []bool, groupBy func(domain.Event) string) []domain.SummaryRow {
	acc := map[string]int64{}
	for i, e := range events {
		if excluded[i] || e.DurationMS <= 0 {
			continue
		}
		k := strings.TrimSpace(groupBy(e))
		if k == "" {
			k = "Unknown"
		}
		acc[k] += e.DurationMS
	}
	out := make([]domain.SummaryRow, 0, len(acc))
	for k, v := range acc {
		out = append(out, domain.SummaryRow{Name: k, TotalMS: v})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].TotalMS == out[j].TotalMS {
			return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
		}
		return out[i].TotalMS > out[j].TotalMS
	})
	return out
}

// buildMappedDetails creates a hierarchical structure of project -> activity -> events
// for mapped events only (events with both project and activity assigned)
func buildMappedDetails(events []domain.Event, excluded []bool) []domain.ProjectDetail {
	// Key: projectID -> activityID -> events
	type activityKey struct {
		projectID  int64
		activityID int64
	}

	projectMap := make(map[int64]*domain.ProjectDetail)
	activityMap := make(map[activityKey]*domain.ActivityDetail)

	for i, e := range events {
		if excluded[i] || e.DurationMS <= 0 {
			continue
		}
		// Only include mapped events
		if e.ProjectID == nil || e.ActivityID == nil {
			continue
		}

		projID := *e.ProjectID
		actID := *e.ActivityID

		// Get or create project
		proj, ok := projectMap[projID]
		if !ok {
			proj = &domain.ProjectDetail{
				ProjectID:    projID,
				ProjectTitle: e.ProjectTitle,
				Activities:   []domain.ActivityDetail{},
			}
			projectMap[projID] = proj
		}
		proj.TotalMS += e.DurationMS

		// Get or create activity
		aKey := activityKey{projID, actID}
		act, ok := activityMap[aKey]
		if !ok {
			act = &domain.ActivityDetail{
				ActivityID:   actID,
				ActivityName: e.ActivityName,
				Events:       []domain.MappedEventDetail{},
			}
			activityMap[aKey] = act
		}
		act.TotalMS += e.DurationMS

		// Add event detail
		act.Events = append(act.Events, domain.MappedEventDetail{
			TimestampMS: e.TimestampMS,
			DurationMS:  e.DurationMS,
			AppName:     e.AppName,
			WindowTitle: e.WindowTitle,
		})
	}

	// Build result slice and associate activities with projects
	result := make([]domain.ProjectDetail, 0, len(projectMap))
	for projID, proj := range projectMap {
		// Find all activities for this project
		for aKey, act := range activityMap {
			if aKey.projectID == projID {
				// Sort events by timestamp
				sort.Slice(act.Events, func(i, j int) bool {
					return act.Events[i].TimestampMS < act.Events[j].TimestampMS
				})
				proj.Activities = append(proj.Activities, *act)
			}
		}
		// Sort activities by total duration descending
		sort.Slice(proj.Activities, func(i, j int) bool {
			return proj.Activities[i].TotalMS > proj.Activities[j].TotalMS
		})
		result = append(result, *proj)
	}

	// Sort projects by total duration descending
	sort.Slice(result, func(i, j int) bool {
		return result[i].TotalMS > result[j].TotalMS
	})

	return result
}

func NormalizeRange(v string) string {
	switch v {
	case "today", "week", "all":
		return v
	default:
		return "today"
	}
}

func NormalizeReportDate(raw string) *string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	parsed, err := time.ParseInLocation("2006-01-02", raw, time.Local)
	if err != nil {
		return nil
	}
	normalized := parsed.Format("2006-01-02")
	return &normalized
}

func PreviousDate(raw string) string {
	normalized := NormalizeReportDate(raw)
	base := time.Now()
	if normalized != nil {
		base, _ = time.ParseInLocation("2006-01-02", *normalized, time.Local)
	}
	return base.AddDate(0, 0, -1).Format("2006-01-02")
}

func NextDate(raw string) string {
	normalized := NormalizeReportDate(raw)
	base := time.Now()
	if normalized != nil {
		base, _ = time.ParseInLocation("2006-01-02", *normalized, time.Local)
	}
	return base.AddDate(0, 0, 1).Format("2006-01-02")
}

func RangeStart(rangeKey string, now time.Time) *int64 {
	switch rangeKey {
	case "week":
		ms := now.AddDate(0, 0, -7).UnixMilli()
		return &ms
	case "all":
		return nil
	default:
		y, m, d := now.Date()
		from := time.Date(y, m, d, 0, 0, 0, 0, now.Location()).UnixMilli()
		return &from
	}
}

func valueOrEmpty(v *string) string {
	if v == nil {
		return ""
	}
	return *v
}
