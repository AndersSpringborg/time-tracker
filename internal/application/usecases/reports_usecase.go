package usecases

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"time-tracker/internal/application/contracts"
	"time-tracker/internal/application/ports"
	"time-tracker/internal/domain"
)

const defaultTimelineStartHour = 8
const defaultTimelineEndHour = 17

type ReportsUsecase struct {
	reportsRepo   ports.ReportsRepository
	projectsRepo  ports.ProjectsRepository
	settingsRepo  ports.SettingsRepository
	summariesRepo ports.SummaryRepository
}

// WithSummaries adds the summarised history of days whose detail retention has
// deleted. Without it, reports read raw events only, as they always have.
func (u *ReportsUsecase) WithSummaries(summaries ports.SummaryRepository) *ReportsUsecase {
	next := *u
	next.summariesRepo = summaries
	return &next
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
	workMask := buildWorkMask(items, cfg.WorkWifis)

	out := domain.Dashboard{CurrentProject: curName, CurrentProjectID: curID}
	for i, e := range items {
		if e.DurationMS <= 0 {
			continue
		}
		out.TrackedEvents++
		out.TodayTotalMS += e.DurationMS
		if workMask[i] {
			out.WorkEvents++
			out.WorkTodayMS += e.DurationMS
		}
	}
	out.TopApps = summarize(items, workMask, func(e domain.Event) string { return e.AppName })
	if len(out.TopApps) > 8 {
		out.TopApps = out.TopApps[:8]
	}
	out.ByProject = summarize(items, workMask, func(e domain.Event) string {
		if strings.TrimSpace(e.ProjectTitle) == "" {
			return "Unmapped"
		}
		return e.ProjectTitle
	})
	out.ByActivity = summarize(items, workMask, func(e domain.Event) string {
		if strings.TrimSpace(e.ActivityName) == "" {
			return "Unmapped"
		}
		return e.ActivityName
	})
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
	workMask := buildWorkMask(items, cfg.WorkWifis)

	out := domain.Report{Range: rangeKey}
	for i, e := range items {
		if e.DurationMS <= 0 {
			continue
		}
		out.TotalEvents++
		out.TotalMS += e.DurationMS
		if !workMask[i] {
			continue
		}
		out.WorkEvents++
		out.WorkMS += e.DurationMS
		if e.ProjectID != nil && e.ActivityID != nil {
			out.MappedEvents++
			out.MappedMS += e.DurationMS
		} else {
			out.UnmappedEvents++
			out.UnmappedMS += e.DurationMS
		}
	}
	out.ByProject = summarize(items, workMask, func(e domain.Event) string {
		if strings.TrimSpace(e.ProjectTitle) == "" {
			return "Unmapped"
		}
		return e.ProjectTitle
	})
	out.ByActivity = summarize(items, workMask, func(e domain.Event) string {
		if strings.TrimSpace(e.ActivityName) == "" {
			return "Unmapped"
		}
		return e.ActivityName
	})
	out.ByApp = summarize(items, workMask, func(e domain.Event) string { return e.AppName })
	out.ByWifi = summarize(items, workMask, func(e domain.Event) string {
		if strings.TrimSpace(e.WifiSSID) == "" {
			return "(none)"
		}
		return e.WifiSSID
	})
	if len(out.ByWifi) > 12 {
		out.ByWifi = out.ByWifi[:12]
	}
	out.ByWindow = summarize(items, workMask, func(e domain.Event) string {
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
	out.MappedDetails = buildMappedDetails(items, workMask)

	// Summarised days contribute totals only: their window detail, timeline and
	// per-event review no longer exist, so they are deliberately absent from
	// ByWindow and MappedDetails rather than faked.
	if err := u.addSummarizedHistory(ctx, &out, rangeKey, reportDate, cfg); err != nil {
		return contracts.ReportsBuildResponse{}, err
	}

	return contracts.ReportsBuildResponse{Report: out}, nil
}

func (u *ReportsUsecase) Timeline(ctx context.Context, req contracts.ReportsTimelineRequest) (contracts.ReportsTimelineResponse, error) {
	reportDate := NormalizeReportDate(valueOrEmpty(req.Date))
	if reportDate == nil {
		today := time.Now().Format("2006-01-02")
		reportDate = &today
	}
	startHour, endHour := NormalizeTimelineHours(req.StartHour, req.EndHour)
	items, err := u.reportsRepo.ListReportEvents(ctx, "all", reportDate)
	if err != nil {
		return contracts.ReportsTimelineResponse{}, err
	}
	timeline := buildTimelineDay(*reportDate, startHour, endHour, items)
	if u.summariesRepo != nil {
		days, err := u.summariesRepo.SummarizedDays(ctx, "all", reportDate)
		if err != nil {
			return contracts.ReportsTimelineResponse{}, err
		}
		timeline.DetailUnavailable = len(days) > 0
	}
	return contracts.ReportsTimelineResponse{Timeline: timeline}, nil
}

func buildTimelineDay(date string, startHour, endHour int, events []domain.Event) domain.TimelineDay {
	out := domain.TimelineDay{
		Date:      date,
		StartHour: startHour,
		EndHour:   endHour,
		HourMarks: buildTimelineHourMarks(startHour, endHour),
		Events:    []domain.TimelineEvent{},
	}
	if len(events) == 0 {
		return out
	}

	ordered := make([]domain.Event, len(events))
	copy(ordered, events)
	sort.Slice(ordered, func(i, j int) bool {
		if ordered[i].TimestampMS == ordered[j].TimestampMS {
			return ordered[i].ID < ordered[j].ID
		}
		return ordered[i].TimestampMS < ordered[j].TimestampMS
	})

	dayStart, err := time.ParseInLocation("2006-01-02", date, time.Local)
	if err != nil {
		first := time.UnixMilli(ordered[0].TimestampMS).In(time.Local)
		y, m, d := first.Date()
		dayStart = time.Date(y, m, d, 0, 0, 0, 0, first.Location())
	}
	windowStart := dayStart.Add(time.Duration(startHour) * time.Hour)
	windowEnd := dayStart.Add(time.Duration(endHour) * time.Hour)
	windowSpanMS := float64(windowEnd.Sub(windowStart).Milliseconds())
	if windowSpanMS <= 0 {
		windowSpanMS = 1
	}

	for _, item := range ordered {
		if item.DurationMS <= 0 {
			continue
		}
		start := time.UnixMilli(item.TimestampMS).In(time.Local)
		end := start.Add(time.Duration(item.DurationMS) * time.Millisecond)
		if end.Before(start) {
			end = start
		}
		event := domain.TimelineEvent{
			EventID:       item.ID,
			StartLabel:    start.Format("15:04"),
			EndLabel:      end.Format("15:04"),
			DurationMS:    item.DurationMS,
			AppName:       strings.TrimSpace(item.AppName),
			WindowTitle:   strings.TrimSpace(item.WindowTitle),
			ProjectTitle:  strings.TrimSpace(item.ProjectTitle),
			ActivityName:  strings.TrimSpace(item.ActivityName),
			WifiSSID:      strings.TrimSpace(item.WifiSSID),
			IsMapped:      item.ProjectID != nil && item.ActivityID != nil,
			InView:        false,
			TopPercent:    0,
			HeightPercent: 0,
		}
		if event.AppName == "" {
			event.AppName = "Unknown App"
		}
		if event.WindowTitle == "" {
			event.WindowTitle = "(empty title)"
		}
		if event.WifiSSID == "" {
			event.WifiSSID = "(none)"
		}

		out.TotalEvents++
		out.TotalMS += item.DurationMS

		visibleStart := start
		if visibleStart.Before(windowStart) {
			visibleStart = windowStart
		}
		visibleEnd := end
		if visibleEnd.After(windowEnd) {
			visibleEnd = windowEnd
		}
		if visibleEnd.After(visibleStart) {
			visibleMS := visibleEnd.Sub(visibleStart).Milliseconds()
			top := float64(visibleStart.Sub(windowStart).Milliseconds()) / windowSpanMS * 100
			height := float64(visibleMS) / windowSpanMS * 100
			if top+height > 100 {
				height = 100 - top
			}
			event.InView = true
			event.TopPercent = top
			event.HeightPercent = height
			out.VisibleEvents++
			out.VisibleMS += visibleMS
		}
		out.Events = append(out.Events, event)
	}

	return out
}

func buildTimelineHourMarks(startHour, endHour int) []domain.TimelineHourMark {
	totalHours := endHour - startHour
	if totalHours <= 0 {
		return nil
	}
	out := make([]domain.TimelineHourMark, 0, totalHours+1)
	for idx := 0; idx <= totalHours; idx++ {
		hour := startHour + idx
		label := fmt.Sprintf("%02d:00", hour)
		top := float64(idx) / float64(totalHours) * 100
		out = append(out, domain.TimelineHourMark{
			Hour:       hour,
			Label:      label,
			TopPercent: top,
		})
	}
	return out
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

func summarize(events []domain.Event, include []bool, groupBy func(domain.Event) string) []domain.SummaryRow {
	acc := map[string]int64{}
	for i, e := range events {
		if !include[i] || e.DurationMS <= 0 {
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

func buildWorkMask(events []domain.Event, workWifis []string) []bool {
	mask := make([]bool, len(events))
	for i, e := range events {
		mask[i] = domain.IsWorkWifi(e.WifiSSID, workWifis)
	}
	return mask
}

// buildMappedDetails creates a hierarchical structure of project -> activity -> events
// for mapped events only (events with both project and activity assigned)
func buildMappedDetails(events []domain.Event, include []bool) []domain.ProjectDetail {
	// Key: projectID -> activityID -> events
	type activityKey struct {
		projectID  int64
		activityID int64
	}

	projectMap := make(map[int64]*domain.ProjectDetail)
	activityMap := make(map[activityKey]*domain.ActivityDetail)

	for i, e := range events {
		if !include[i] || e.DurationMS <= 0 {
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
			WifiSSID:    e.WifiSSID,
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

func NormalizeTimelineHours(startHour, endHour int) (int, int) {
	if startHour < 0 || startHour > 23 {
		startHour = defaultTimelineStartHour
	}
	if endHour < 1 || endHour > 24 {
		endHour = defaultTimelineEndHour
	}
	if endHour <= startHour {
		return defaultTimelineStartHour, defaultTimelineEndHour
	}
	return startHour, endHour
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

// addSummarizedHistory folds days served from summaries into the report's
// totals and breakdowns. Work classification is applied here, from current
// settings, so editing work wifis still reclassifies summarised history.
func (u *ReportsUsecase) addSummarizedHistory(
	ctx context.Context,
	out *domain.Report,
	rangeKey string,
	date *string,
	cfg domain.Settings,
) error {
	if u.summariesRepo == nil {
		return nil
	}
	contributions, err := u.summariesRepo.ListSummaryContributions(ctx, rangeKey, date)
	if err != nil {
		return err
	}
	days, err := u.summariesRepo.SummarizedDays(ctx, rangeKey, date)
	if err != nil {
		return err
	}
	out.SummarizedDays = days

	byProject := map[string]int64{}
	byActivity := map[string]int64{}
	byApp := map[string]int64{}
	byWifi := map[string]int64{}
	for _, contribution := range contributions {
		if contribution.TotalMS <= 0 {
			continue
		}
		out.TotalEvents += contribution.EventCount
		out.TotalMS += contribution.TotalMS
		if !domain.IsWorkWifi(contribution.WifiSSID, cfg.WorkWifis) {
			continue
		}
		out.WorkEvents += contribution.EventCount
		out.WorkMS += contribution.TotalMS
		if strings.TrimSpace(contribution.ProjectTitle) != "" && strings.TrimSpace(contribution.ActivityName) != "" {
			out.MappedEvents += contribution.EventCount
			out.MappedMS += contribution.TotalMS
		} else {
			out.UnmappedEvents += contribution.EventCount
			out.UnmappedMS += contribution.TotalMS
		}
		byProject[nameOrUnmapped(contribution.ProjectTitle)] += contribution.TotalMS
		byActivity[nameOrUnmapped(contribution.ActivityName)] += contribution.TotalMS
		byApp[contribution.AppName] += contribution.TotalMS
		byWifi[wifiOrNone(contribution.WifiSSID)] += contribution.TotalMS
	}

	out.ByProject = mergeSummaryRows(out.ByProject, byProject)
	out.ByActivity = mergeSummaryRows(out.ByActivity, byActivity)
	out.ByApp = mergeSummaryRows(out.ByApp, byApp)
	out.ByWifi = mergeSummaryRows(out.ByWifi, byWifi)
	if len(out.ByWifi) > 12 {
		out.ByWifi = out.ByWifi[:12]
	}
	return nil
}

func nameOrUnmapped(name string) string {
	if strings.TrimSpace(name) == "" {
		return "Unmapped"
	}
	return name
}

func wifiOrNone(ssid string) string {
	if strings.TrimSpace(ssid) == "" {
		return "(none)"
	}
	return ssid
}

// mergeSummaryRows adds summarised totals to rows built from raw events,
// keeping one row per name so nothing is counted twice.
func mergeSummaryRows(rows []domain.SummaryRow, extra map[string]int64) []domain.SummaryRow {
	if len(extra) == 0 {
		return rows
	}
	merged := make(map[string]int64, len(rows)+len(extra))
	order := make([]string, 0, len(rows)+len(extra))
	for _, row := range rows {
		if _, seen := merged[row.Name]; !seen {
			order = append(order, row.Name)
		}
		merged[row.Name] += row.TotalMS
	}
	for name, totalMS := range extra {
		if _, seen := merged[name]; !seen {
			order = append(order, name)
		}
		merged[name] += totalMS
	}
	out := make([]domain.SummaryRow, 0, len(order))
	for _, name := range order {
		out = append(out, domain.SummaryRow{Name: name, TotalMS: merged[name]})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].TotalMS != out[j].TotalMS {
			return out[i].TotalMS > out[j].TotalMS
		}
		return out[i].Name < out[j].Name
	})
	return out
}
