package duckdb

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"time-tracker/internal/domain"
)

type Store struct {
	db *sql.DB
}

func Open(path string) (*Store, error) {
	d, err := openDB(path)
	if err != nil {
		return nil, err
	}
	return &Store{db: d}, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) ListRules(ctx context.Context) ([]domain.Rule, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT
  mr.id,
  mr.priority,
  COALESCE(mr.app_pattern, ''),
  COALESCE(mr.title_pattern, ''),
  mr.activity_id,
  mr.kind_id,
  COALESCE(mr.follow_previous, false),
  COALESCE(mr.is_global, false),
  COALESCE(mr.kind_name, ''),
  COALESCE(c.name, ''),
  COALESCE(p.name, ''),
  COALESCE(ph.name, ''),
  COALESCE(a.name, ''),
  COALESCE(k.name, '')
FROM mapping_rules mr
LEFT JOIN activities a ON a.activity_id = mr.activity_id
LEFT JOIN phases ph ON ph.phase_id = a.phase_id
LEFT JOIN projects p ON p.project_id = ph.project_id
LEFT JOIN customers c ON c.customer_id = p.customer_id
LEFT JOIN kinds k ON k.activity_id = mr.activity_id AND k.kind_id = mr.kind_id
ORDER BY mr.priority DESC, mr.id DESC
`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []domain.Rule
	for rows.Next() {
		var r domain.Rule
		var customer, project, phase, activity, kind string
		if err := rows.Scan(
			&r.ID,
			&r.Priority,
			&r.AppPattern,
			&r.TitlePattern,
			&r.ActivityID,
			&r.KindID,
			&r.FollowPrevious,
			&r.IsGlobal,
			&r.KindName,
			&customer,
			&project,
			&phase,
			&activity,
			&kind,
		); err != nil {
			return nil, err
		}
		r.DisplayTarget = buildDisplayTarget(r, customer, project, phase, activity, kind)
		out = append(out, r)
	}
	return out, rows.Err()
}

func buildDisplayTarget(r domain.Rule, customer, project, phase, activity, kind string) string {
	if r.FollowPrevious {
		return "Follow current project"
	}
	if r.IsGlobal && r.KindName != "" {
		return "Global kind: " + r.KindName
	}
	parts := []string{}
	for _, p := range []string{customer, project, phase, activity, kind} {
		if p != "" {
			parts = append(parts, p)
		}
	}
	if len(parts) == 0 {
		return "Unmapped"
	}
	return strings.Join(parts, " > ")
}

func (s *Store) AddRule(ctx context.Context, in domain.RuleInput) (int64, error) {
	if in.Priority == 0 {
		in.Priority = 100
	}
	if strings.TrimSpace(in.AppPattern) == "" {
		in.AppPattern = "*"
	}
	if strings.TrimSpace(in.TitlePattern) == "" {
		in.TitlePattern = "*"
	}
	if in.FollowPrevious {
		in.ActivityID = nil
		in.KindID = nil
		in.IsGlobal = false
		in.KindName = ""
	}
	if in.IsGlobal {
		in.ActivityID = nil
		in.KindID = nil
	}

	res, err := s.db.ExecContext(ctx, `
INSERT INTO mapping_rules (
  priority, app_pattern, title_pattern, activity_id, kind_id, follow_previous, is_global, kind_name
) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
`, in.Priority, nullIfEmpty(in.AppPattern), nullIfEmpty(in.TitlePattern), in.ActivityID, in.KindID, in.FollowPrevious, in.IsGlobal, nullIfEmpty(in.KindName))
	if err != nil {
		return 0, err
	}
	id, _ := res.LastInsertId()
	return id, nil
}

func (s *Store) DeleteRule(ctx context.Context, id int64) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM mapping_rules WHERE id = ?`, id)
	return err
}

func (s *Store) AnalyzeSuggestions(ctx context.Context, q domain.SuggestionQuery) ([]domain.RuleSuggestion, error) {
	if q.MinDurationMS <= 0 {
		q.MinDurationMS = 2000
	}
	if q.Limit <= 0 {
		q.Limit = 50
	}

	appSuggestions, err := s.analyzeAppSuggestions(ctx, q)
	if err != nil {
		return nil, err
	}
	titleSuggestions, err := s.analyzeTitleSuggestions(ctx, q)
	if err != nil {
		return nil, err
	}

	all := append(appSuggestions, titleSuggestions...)
	sort.Slice(all, func(i, j int) bool {
		if all[i].ImpactDurationMS == all[j].ImpactDurationMS {
			return all[i].Confidence > all[j].Confidence
		}
		return all[i].ImpactDurationMS > all[j].ImpactDurationMS
	})
	if len(all) > q.Limit {
		all = all[:q.Limit]
	}
	return all, nil
}

func (s *Store) analyzeAppSuggestions(ctx context.Context, q domain.SuggestionQuery) ([]domain.RuleSuggestion, error) {
	where := "WHERE activity_id IS NULL AND manually_mapped = false AND duration_ms >= ?"
	args := []any{q.MinDurationMS}
	if q.Date != nil && *q.Date != "" {
		where += " AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?"
		args = append(args, *q.Date)
	}

	query := `
WITH mapped AS (
  SELECT app_name, activity_id, kind_id, COUNT(*) AS cnt
  FROM events
  WHERE activity_id IS NOT NULL AND kind_id IS NOT NULL
  GROUP BY app_name, activity_id, kind_id
), app_totals AS (
  SELECT app_name, SUM(cnt) AS total_cnt
  FROM mapped GROUP BY app_name
), top_map AS (
  SELECT m.*, ROW_NUMBER() OVER (PARTITION BY m.app_name ORDER BY m.cnt DESC) AS rn
  FROM mapped m
), unmapped AS (
  SELECT app_name, COUNT(*) AS impact_count, COALESCE(SUM(duration_ms),0) AS impact_duration_ms
  FROM events
  ` + where + `
  GROUP BY app_name
)
SELECT tm.app_name, tm.activity_id, tm.kind_id,
       CAST(tm.cnt * 100.0 / NULLIF(app_tot.total_cnt,0) AS INTEGER) AS confidence,
       u.impact_count, u.impact_duration_ms, tm.cnt
FROM top_map tm
JOIN app_totals app_tot ON app_tot.app_name = tm.app_name
JOIN unmapped u ON u.app_name = tm.app_name
WHERE tm.rn = 1 AND u.impact_count > 0
ORDER BY u.impact_duration_ms DESC
LIMIT ?
`
	args = append(args, q.Limit)

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]domain.RuleSuggestion, 0)
	for rows.Next() {
		var app string
		var activityID, kindID int64
		var confidence, impactCount, evidence int
		var impactDuration int64
		if err := rows.Scan(&app, &activityID, &kindID, &confidence, &impactCount, &impactDuration, &evidence); err != nil {
			return nil, err
		}
		if confidence < 60 {
			continue
		}
		path, _ := s.getDisplayPath(ctx, activityID, kindID)
		out = append(out, domain.RuleSuggestion{
			SuggestionType:   domain.SuggestionTypeAppOnly,
			AppPattern:       app,
			TitlePattern:     nil,
			ActivityID:       activityID,
			KindID:           kindID,
			DisplayPath:      path,
			Confidence:       confidence,
			ImpactCount:      impactCount,
			ImpactDurationMS: impactDuration,
			EvidenceCount:    evidence,
		})
	}
	return out, rows.Err()
}

func (s *Store) analyzeTitleSuggestions(ctx context.Context, q domain.SuggestionQuery) ([]domain.RuleSuggestion, error) {
	where := "WHERE activity_id IS NULL AND manually_mapped = false AND duration_ms >= ?"
	args := []any{q.MinDurationMS}
	if q.Date != nil && *q.Date != "" {
		where += " AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?"
		args = append(args, *q.Date)
	}

	query := `
WITH mapped_title AS (
  SELECT app_name, window_title, activity_id, kind_id, COUNT(*) AS cnt
  FROM events
  WHERE activity_id IS NOT NULL AND kind_id IS NOT NULL AND window_title <> ''
  GROUP BY app_name, window_title, activity_id, kind_id
), unmapped_title AS (
  SELECT app_name, window_title, COUNT(*) AS impact_count, COALESCE(SUM(duration_ms),0) AS impact_duration_ms
  FROM events
  ` + where + `
  GROUP BY app_name, window_title
)
SELECT m.app_name, m.window_title, m.activity_id, m.kind_id, m.cnt, u.impact_count, u.impact_duration_ms
FROM mapped_title m
JOIN unmapped_title u
  ON u.app_name = m.app_name AND u.window_title = m.window_title
WHERE m.cnt >= 2 AND u.impact_count > 0
ORDER BY u.impact_duration_ms DESC
LIMIT ?
`
	args = append(args, q.Limit)

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]domain.RuleSuggestion, 0)
	for rows.Next() {
		var app, title string
		var activityID, kindID int64
		var evidence, impactCount int
		var impactDuration int64
		if err := rows.Scan(&app, &title, &activityID, &kindID, &evidence, &impactCount, &impactDuration); err != nil {
			return nil, err
		}
		pattern := titlePattern(title)
		path, _ := s.getDisplayPath(ctx, activityID, kindID)
		out = append(out, domain.RuleSuggestion{
			SuggestionType:   domain.SuggestionTypeAppAndTitle,
			AppPattern:       app,
			TitlePattern:     &pattern,
			ActivityID:       activityID,
			KindID:           kindID,
			DisplayPath:      path,
			Confidence:       85,
			ImpactCount:      impactCount,
			ImpactDurationMS: impactDuration,
			EvidenceCount:    evidence,
		})
	}
	return out, rows.Err()
}

func titlePattern(title string) string {
	t := strings.TrimSpace(title)
	if t == "" {
		return "*"
	}
	if len(t) > 80 {
		t = t[:80]
	}
	return "*" + t + "*"
}

func (s *Store) getDisplayPath(ctx context.Context, activityID, kindID int64) (string, error) {
	var path string
	err := s.db.QueryRowContext(ctx, `
SELECT COALESCE(c.name || ' > ' || p.name || ' > ' || ph.name || ' > ' || a.name || ' > ' || k.name, '')
FROM kinds k
JOIN activities a ON k.activity_id = a.activity_id
JOIN phases ph ON a.phase_id = ph.phase_id
JOIN projects p ON ph.project_id = p.project_id
JOIN customers c ON p.customer_id = c.customer_id
WHERE a.activity_id = ? AND k.kind_id = ?
LIMIT 1
`, activityID, kindID).Scan(&path)
	if err != nil {
		return "", err
	}
	return path, nil
}

func (s *Store) AcceptSuggestion(ctx context.Context, in domain.ApplySuggestionInput) (domain.ApplySuggestionResult, error) {
	title := "*"
	if in.Suggestion.TitlePattern != nil && strings.TrimSpace(*in.Suggestion.TitlePattern) != "" {
		title = *in.Suggestion.TitlePattern
	}
	activity := in.Suggestion.ActivityID
	kind := in.Suggestion.KindID

	_, err := s.AddRule(ctx, domain.RuleInput{
		Priority:     100,
		AppPattern:   in.Suggestion.AppPattern,
		TitlePattern: title,
		ActivityID:   &activity,
		KindID:       &kind,
	})
	if err != nil {
		return domain.ApplySuggestionResult{}, err
	}

	mapped := int64(0)
	if in.ApplyNow {
		mapped, err = s.applyRuleToUnmapped(ctx, in.Suggestion.AppPattern, in.Suggestion.TitlePattern, in.Suggestion.ActivityID, in.Suggestion.KindID, in.Date)
		if err != nil {
			return domain.ApplySuggestionResult{}, err
		}
	}

	return domain.ApplySuggestionResult{RuleCreated: true, MappedEvents: mapped}, nil
}

func (s *Store) applyRuleToUnmapped(ctx context.Context, appPattern string, titlePattern *string, activityID, kindID int64, date *string) (int64, error) {
	events, err := s.listUnmappedEvents(ctx, date)
	if err != nil {
		return 0, err
	}
	var mapped int64
	for _, e := range events {
		if !glob(appPattern, e.AppName) {
			continue
		}
		if titlePattern != nil && !glob(*titlePattern, e.WindowTitle) {
			continue
		}
		if _, err := s.db.ExecContext(ctx, `UPDATE events SET activity_id = ?, kind_id = ?, manually_mapped = true WHERE id = ?`, activityID, kindID, e.ID); err != nil {
			return mapped, err
		}
		mapped++
	}
	return mapped, nil
}

func (s *Store) listUnmappedEvents(ctx context.Context, date *string) ([]domain.Event, error) {
	query := `SELECT id, timestamp_ms, app_name, window_title, duration_ms FROM events WHERE activity_id IS NULL AND manually_mapped = false`
	args := []any{}
	if date != nil && *date != "" {
		query += ` AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?`
		args = append(args, *date)
	}
	query += ` ORDER BY timestamp_ms ASC`
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domain.Event{}
	for rows.Next() {
		var e domain.Event
		if err := rows.Scan(&e.ID, &e.TimestampMS, &e.AppName, &e.WindowTitle, &e.DurationMS); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func glob(pattern, value string) bool {
	pattern = strings.TrimSpace(pattern)
	if pattern == "" {
		pattern = "*"
	}
	ok, err := filepath.Match(pattern, value)
	if err != nil {
		return false
	}
	return ok
}

func (s *Store) ApplyRules(ctx context.Context, in domain.ApplyRulesInput) (domain.ApplyRulesResult, error) {
	rules, err := s.ListRules(ctx)
	if err != nil {
		return domain.ApplyRulesResult{}, err
	}
	events, err := s.listUnmappedEvents(ctx, in.Date)
	if err != nil {
		return domain.ApplyRulesResult{}, err
	}
	res := domain.ApplyRulesResult{UnmappedEvents: int64(len(events))}

	var prevActivity *int64
	var prevKind *int64
	for _, e := range events {
		matched := false
		for _, r := range rules {
			if !glob(orDefault(r.AppPattern, "*"), e.AppName) {
				continue
			}
			if !glob(orDefault(r.TitlePattern, "*"), e.WindowTitle) {
				continue
			}
			if r.FollowPrevious {
				if prevActivity == nil || prevKind == nil {
					continue
				}
				if !in.DryRun {
					if _, err := s.db.ExecContext(ctx, `UPDATE events SET activity_id = ?, kind_id = ? WHERE id = ?`, *prevActivity, *prevKind, e.ID); err != nil {
						return res, err
					}
				}
				res.MatchedEvents++
				matched = true
				break
			}
			if r.ActivityID == nil || r.KindID == nil {
				continue
			}
			if !in.DryRun {
				if _, err := s.db.ExecContext(ctx, `UPDATE events SET activity_id = ?, kind_id = ? WHERE id = ?`, *r.ActivityID, *r.KindID, e.ID); err != nil {
					return res, err
				}
			}
			a := *r.ActivityID
			k := *r.KindID
			prevActivity = &a
			prevKind = &k
			res.MatchedEvents++
			matched = true
			break
		}
		if !matched {
			continue
		}
	}
	return res, nil
}

func orDefault(v, d string) string {
	if strings.TrimSpace(v) == "" {
		return d
	}
	return v
}

func (s *Store) ListReportEvents(ctx context.Context, rangeKey string) ([]domain.Event, error) {
	where, args := rangeFilter(rangeKey)
	query := `
SELECT
  e.id,
  e.timestamp_ms,
  e.duration_ms,
  e.app_name,
  e.window_title,
  COALESCE(c.name || ' > ' || p.name, '') as project_name
FROM events e
LEFT JOIN activities a ON a.activity_id = e.activity_id
LEFT JOIN phases ph ON ph.phase_id = a.phase_id
LEFT JOIN projects p ON p.project_id = ph.project_id
LEFT JOIN customers c ON c.customer_id = p.customer_id
` + where + `
ORDER BY e.timestamp_ms ASC
`
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []domain.Event
	for rows.Next() {
		var e domain.Event
		if err := rows.Scan(&e.ID, &e.TimestampMS, &e.DurationMS, &e.AppName, &e.WindowTitle, &e.ProjectName); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func rangeFilter(rangeKey string) (string, []any) {
	now := time.Now()
	switch rangeKey {
	case "week":
		from := now.AddDate(0, 0, -7).UnixMilli()
		return `WHERE e.timestamp_ms >= ?`, []any{from}
	case "all":
		return ``, nil
	default:
		y, m, d := now.Date()
		from := time.Date(y, m, d, 0, 0, 0, 0, now.Location()).UnixMilli()
		return `WHERE e.timestamp_ms >= ?`, []any{from}
	}
}

func (s *Store) ListActiveProjects(ctx context.Context) ([]domain.Project, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT pa.project_id, c.name, p.name, CAST(pa.started_at AS VARCHAR)
FROM project_assignments pa
JOIN projects p ON p.project_id = pa.project_id
JOIN customers c ON c.customer_id = p.customer_id
WHERE pa.ended_at IS NULL
ORDER BY pa.started_at DESC
`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []domain.Project
	for rows.Next() {
		var p domain.Project
		if err := rows.Scan(&p.ProjectID, &p.Customer, &p.Name, &p.StartedAt); err != nil {
			return nil, err
		}
		p.Active = true
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Store) ListAllProjects(ctx context.Context) ([]domain.Project, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT p.project_id, c.name, p.name
FROM projects p
JOIN customers c ON c.customer_id = p.customer_id
ORDER BY c.name, p.name
`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []domain.Project
	for rows.Next() {
		var p domain.Project
		if err := rows.Scan(&p.ProjectID, &p.Customer, &p.Name); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Store) ActivateProject(ctx context.Context, projectID int64) error {
	var count int64
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM project_assignments WHERE project_id = ? AND ended_at IS NULL`, projectID).Scan(&count); err != nil {
		return err
	}
	if count > 0 {
		return nil
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO project_assignments (project_id) VALUES (?)`, projectID)
	return err
}

func (s *Store) EndProject(ctx context.Context, projectID int64) error {
	_, err := s.db.ExecContext(ctx, `UPDATE project_assignments SET ended_at = current_timestamp WHERE project_id = ? AND ended_at IS NULL`, projectID)
	return err
}

func (s *Store) EndAllProjects(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `UPDATE project_assignments SET ended_at = current_timestamp WHERE ended_at IS NULL`)
	return err
}

func (s *Store) CurrentProject(ctx context.Context) (string, *int64, error) {
	var id int64
	var name string
	err := s.db.QueryRowContext(ctx, `
SELECT pa.project_id, c.name || ' > ' || p.name
FROM project_assignments pa
JOIN projects p ON p.project_id = pa.project_id
JOIN customers c ON c.customer_id = p.customer_id
WHERE pa.ended_at IS NULL
ORDER BY pa.started_at DESC
LIMIT 1
`).Scan(&id, &name)
	if err != nil {
		if err == sql.ErrNoRows {
			return "None", nil, nil
		}
		return "", nil, err
	}
	return name, &id, nil
}

func (s *Store) ListUnmappedDates(ctx context.Context, minDurationMS int64) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT DISTINCT CAST(DATE(TO_TIMESTAMP(timestamp_ms / 1000)) AS VARCHAR)
FROM events
WHERE activity_id IS NULL AND manually_mapped = false AND duration_ms >= ?
ORDER BY 1 DESC
`, minDurationMS)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var d string
		if err := rows.Scan(&d); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

func (s *Store) ListGroupedUnmappedEvents(ctx context.Context, date string, minDurationMS int64) ([]domain.GroupedEvent, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT app_name, window_title, COALESCE(SUM(duration_ms),0), COUNT(*)
FROM events
WHERE activity_id IS NULL AND manually_mapped = false
  AND duration_ms >= ?
  AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
GROUP BY app_name, window_title
ORDER BY 3 DESC
`, minDurationMS, date)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domain.GroupedEvent{}
	for rows.Next() {
		var g domain.GroupedEvent
		if err := rows.Scan(&g.AppName, &g.WindowTitle, &g.TotalDurationMS, &g.EventCount); err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

func (s *Store) MapEventsByGroup(ctx context.Context, date, appName, windowTitle string, activityID, kindID int64) (int64, error) {
	res, err := s.db.ExecContext(ctx, `
UPDATE events
SET activity_id = ?, kind_id = ?, manually_mapped = true
WHERE activity_id IS NULL AND manually_mapped = false
  AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
  AND app_name = ? AND window_title = ?
`, activityID, kindID, date, appName, windowTitle)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return n, nil
}

func (s *Store) DiscardEventsByGroup(ctx context.Context, date, appName, windowTitle string) (int64, error) {
	res, err := s.db.ExecContext(ctx, `
UPDATE events
SET manually_mapped = true
WHERE activity_id IS NULL AND manually_mapped = false
  AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
  AND app_name = ? AND window_title = ?
`, date, appName, windowTitle)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return n, nil
}

func nullIfEmpty(v string) any {
	v = strings.TrimSpace(v)
	if v == "" {
		return nil
	}
	return v
}

var (
	_ interface{ Close() error } = (*Store)(nil)
)

func (s *Store) String() string { return fmt.Sprintf("duckdb-store(%p)", s.db) }
