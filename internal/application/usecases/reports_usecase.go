package usecases

import (
	"context"
	"sort"
	"strings"
	"time"

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

func (u *ReportsUsecase) Dashboard(ctx context.Context) (domain.Dashboard, error) {
	cfg, _, err := u.settingsRepo.Load(ctx)
	if err != nil {
		return domain.Dashboard{}, err
	}
	curName, curID, err := u.projectsRepo.CurrentProject(ctx)
	if err != nil {
		return domain.Dashboard{}, err
	}
	items, err := u.reportsRepo.ListReportEvents(ctx, "today")
	if err != nil {
		return domain.Dashboard{}, err
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
	return out, nil
}

func (u *ReportsUsecase) Report(ctx context.Context, rangeKey string) (domain.Report, error) {
	cfg, _, err := u.settingsRepo.Load(ctx)
	if err != nil {
		return domain.Report{}, err
	}
	items, err := u.reportsRepo.ListReportEvents(ctx, rangeKey)
	if err != nil {
		return domain.Report{}, err
	}
	mask := domain.BuildNoiseMask(items, cfg.NoiseAppPatterns, cfg.NoiseBucketMinutes, cfg.NoiseSwitchMinutes)

	out := domain.Report{Range: rangeKey}
	for i, e := range items {
		if e.DurationMS <= 0 {
			continue
		}
		if mask[i] {
			out.ExcludedEvents++
			continue
		}
		out.TotalMS += e.DurationMS
	}
	out.ByProject = summarize(items, mask, func(e domain.Event) string {
		if strings.TrimSpace(e.ProjectName) == "" {
			return "Unmapped"
		}
		return e.ProjectName
	})
	out.ByApp = summarize(items, mask, func(e domain.Event) string { return e.AppName })
	return out, nil
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

func NormalizeRange(v string) string {
	switch v {
	case "today", "week", "all":
		return v
	default:
		return "today"
	}
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
