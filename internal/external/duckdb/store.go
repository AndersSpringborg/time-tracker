package duckdb

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"time-tracker/internal/domain"
)

type Store struct {
	db *sql.DB
}

type ruleRow struct {
	ID                 int64
	RuleKey            sql.NullString
	Source             string
	Priority           int
	AppPattern         sql.NullString
	TitlePattern       sql.NullString
	ProjectID          sql.NullInt64
	ActivityID         sql.NullInt64
	FollowPrevious     bool
	ActionType         string
	ActionProjectTitle sql.NullString
	ActionActivityName sql.NullString
	ProjectTitle       sql.NullString
	ActivityTitle      sql.NullString
}

func (r ruleRow) toDomainRule() domain.Rule {
	rule := domain.Rule{
		ID:                 r.ID,
		RuleKey:            nullStringValue(r.RuleKey),
		Source:             domain.RuleSource(strings.TrimSpace(r.Source)),
		Priority:           r.Priority,
		AppPattern:         nullStringValue(r.AppPattern),
		TitlePattern:       nullStringValue(r.TitlePattern),
		ProjectID:          nullInt64Ptr(r.ProjectID),
		ActivityID:         nullInt64Ptr(r.ActivityID),
		FollowPrevious:     r.FollowPrevious,
		ActionType:         domain.RuleAction(strings.TrimSpace(r.ActionType)),
		ActionProjectTitle: nullStringValue(r.ActionProjectTitle),
		ActionActivityName: nullStringValue(r.ActionActivityName),
	}
	rule.DisplayTarget = buildDisplayTarget(rule, nullStringValue(r.ProjectTitle), nullStringValue(r.ActivityTitle))
	return rule
}

func Open(path string) (*Store, error) {
	d, err := openDB(path)
	if err != nil {
		return nil, err
	}
	s := &Store{db: d}
	if err := s.convertLegacyGlobRules(context.Background()); err != nil {
		_ = d.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) ListRules(ctx context.Context) ([]domain.Rule, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT
  mr.id,
  COALESCE(mr.rule_key, ''),
  COALESCE(mr.source, 'user'),
  mr.priority,
  COALESCE(mr.app_pattern, ''),
  COALESCE(mr.title_pattern, ''),
  mr.project_id,
  mr.activity_id,
  COALESCE(mr.follow_previous, false),
  COALESCE(mr.action_type, 'assign_explicit'),
  COALESCE(mr.action_project_title, ''),
  COALESCE(mr.action_activity_title, ''),
  COALESCE(p.title, ''),
  COALESCE(a.title, '')
FROM mapping_rules mr
LEFT JOIN projects p ON p.project_id = mr.project_id
LEFT JOIN activities a ON a.activity_id = mr.activity_id
ORDER BY mr.priority DESC, mr.id DESC
`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]domain.Rule, 0)
	for rows.Next() {
		var row ruleRow
		if err := rows.Scan(
			&row.ID,
			&row.RuleKey,
			&row.Source,
			&row.Priority,
			&row.AppPattern,
			&row.TitlePattern,
			&row.ProjectID,
			&row.ActivityID,
			&row.FollowPrevious,
			&row.ActionType,
			&row.ActionProjectTitle,
			&row.ActionActivityName,
			&row.ProjectTitle,
			&row.ActivityTitle,
		); err != nil {
			return nil, err
		}
		out = append(out, row.toDomainRule())
	}
	return out, rows.Err()
}

func buildDisplayTarget(rule domain.Rule, projectTitle, activityTitle string) string {
	switch rule.EffectiveAction() {
	case domain.RuleActionFollowCurrentContext:
		return "Follow current project/activity"
	case domain.RuleActionAssignActivityCurrent:
		if strings.TrimSpace(rule.ActionActivityName) == "" {
			return "Current project > (activity unresolved)"
		}
		return fmt.Sprintf("Current project > %s", rule.ActionActivityName)
	case domain.RuleActionAssignProjectAndActivityByT:
		return fmt.Sprintf("%s > %s", rule.ActionProjectTitle, rule.ActionActivityName)
	}

	parts := make([]string, 0, 2)
	if strings.TrimSpace(projectTitle) != "" {
		parts = append(parts, projectTitle)
	}
	if strings.TrimSpace(activityTitle) != "" {
		parts = append(parts, activityTitle)
	}
	if len(parts) == 0 {
		return "Unmapped"
	}
	return strings.Join(parts, " > ")
}

func (s *Store) AddRule(ctx context.Context, in domain.RuleInput) (int64, error) {
	in = domain.NormalizeRuleInput(in)
	res, err := s.db.ExecContext(ctx, `
INSERT INTO mapping_rules (
  rule_key, source, priority, app_pattern, title_pattern, project_id, activity_id, follow_previous,
  action_type, action_project_title, action_activity_title, pattern_format
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'regex')
`, nullIfEmpty(in.RuleKey), string(orDefaultSource(in.Source)), in.Priority, nullIfEmpty(in.AppPattern), nullIfEmpty(in.TitlePattern),
		in.ProjectID, in.ActivityID, in.FollowPrevious, string(in.ActionType), nullIfEmpty(in.ActionProjectTitle), nullIfEmpty(in.ActionActivityName))
	if err != nil {
		return 0, err
	}
	id, _ := res.LastInsertId()
	return id, nil
}

func (s *Store) UpdateRule(ctx context.Context, id int64, in domain.RuleInput) error {
	in = domain.NormalizeRuleInput(in)
	_, err := s.db.ExecContext(ctx, `
UPDATE mapping_rules
SET rule_key = ?, source = ?, priority = ?, app_pattern = ?, title_pattern = ?,
    project_id = ?, activity_id = ?, follow_previous = ?, action_type = ?,
    action_project_title = ?, action_activity_title = ?, pattern_format = 'regex'
WHERE id = ?
`, nullIfEmpty(in.RuleKey), string(orDefaultSource(in.Source)), in.Priority, nullIfEmpty(in.AppPattern), nullIfEmpty(in.TitlePattern),
		in.ProjectID, in.ActivityID, in.FollowPrevious, string(in.ActionType), nullIfEmpty(in.ActionProjectTitle), nullIfEmpty(in.ActionActivityName), id)
	return err
}

func (s *Store) DeleteRule(ctx context.Context, id int64) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM mapping_rules WHERE id = ?`, id)
	return err
}

func (s *Store) ApplyRulesetChanges(ctx context.Context, in domain.RulesetChanges) (domain.RulesetApplyResult, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.RulesetApplyResult{}, err
	}
	defer func() { _ = tx.Rollback() }()

	deleted := 0
	for _, id := range in.Deletes {
		res, err := tx.ExecContext(ctx, `DELETE FROM mapping_rules WHERE id = ?`, id)
		if err != nil {
			return domain.RulesetApplyResult{}, err
		}
		affected, _ := res.RowsAffected()
		deleted += int(affected)
	}

	updated := 0
	for _, item := range in.Updates {
		inRule := domain.NormalizeRuleInput(item.Rule)
		res, err := tx.ExecContext(ctx, `
UPDATE mapping_rules
SET rule_key = ?, source = ?, priority = ?, app_pattern = ?, title_pattern = ?,
    project_id = ?, activity_id = ?, follow_previous = ?, action_type = ?,
    action_project_title = ?, action_activity_title = ?, pattern_format = 'regex'
WHERE id = ?
`, nullIfEmpty(inRule.RuleKey), string(orDefaultSource(inRule.Source)), inRule.Priority, nullIfEmpty(inRule.AppPattern), nullIfEmpty(inRule.TitlePattern),
			inRule.ProjectID, inRule.ActivityID, inRule.FollowPrevious, string(inRule.ActionType), nullIfEmpty(inRule.ActionProjectTitle), nullIfEmpty(inRule.ActionActivityName), item.ID)
		if err != nil {
			return domain.RulesetApplyResult{}, err
		}
		affected, _ := res.RowsAffected()
		updated += int(affected)
	}

	added := 0
	for _, item := range in.Adds {
		inRule := domain.NormalizeRuleInput(item)
		res, err := tx.ExecContext(ctx, `
INSERT INTO mapping_rules (
  rule_key, source, priority, app_pattern, title_pattern, project_id, activity_id, follow_previous,
  action_type, action_project_title, action_activity_title, pattern_format
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'regex')
`, nullIfEmpty(inRule.RuleKey), string(orDefaultSource(inRule.Source)), inRule.Priority, nullIfEmpty(inRule.AppPattern), nullIfEmpty(inRule.TitlePattern),
			inRule.ProjectID, inRule.ActivityID, inRule.FollowPrevious, string(inRule.ActionType), nullIfEmpty(inRule.ActionProjectTitle), nullIfEmpty(inRule.ActionActivityName))
		if err != nil {
			return domain.RulesetApplyResult{}, err
		}
		affected, _ := res.RowsAffected()
		added += int(affected)
	}

	if err := tx.Commit(); err != nil {
		return domain.RulesetApplyResult{}, err
	}
	return domain.RulesetApplyResult{
		Added:   added,
		Updated: updated,
		Deleted: deleted,
	}, nil
}

func (s *Store) ListUnmappedEvents(ctx context.Context, date *string, minDurationMS int64) ([]domain.Event, error) {
	query := `
SELECT id, timestamp_ms, app_name, window_title, duration_ms
FROM events
WHERE project_id IS NULL AND activity_id IS NULL AND manually_mapped = false
`
	args := make([]any, 0, 2)
	if minDurationMS > 0 {
		query += ` AND duration_ms >= ?`
		args = append(args, minDurationMS)
	}
	if date != nil && strings.TrimSpace(*date) != "" {
		query += ` AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?`
		args = append(args, *date)
	}
	query += ` ORDER BY timestamp_ms ASC, id ASC`
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]domain.Event, 0)
	for rows.Next() {
		var event domain.Event
		if err := rows.Scan(&event.ID, &event.TimestampMS, &event.AppName, &event.WindowTitle, &event.DurationMS); err != nil {
			return nil, err
		}
		out = append(out, event)
	}
	return out, rows.Err()
}

func (s *Store) ListAppSuggestions(ctx context.Context, q domain.SuggestionQuery) ([]domain.RuleSuggestion, error) {
	where := "WHERE project_id IS NULL AND activity_id IS NULL AND manually_mapped = false"
	args := make([]any, 0, 3)
	if q.MinDurationMS > 0 {
		where += " AND duration_ms >= ?"
		args = append(args, q.MinDurationMS)
	}
	if q.Date != nil && strings.TrimSpace(*q.Date) != "" {
		where += " AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?"
		args = append(args, *q.Date)
	}
	limit := q.Limit
	if limit <= 0 {
		limit = 50
	}

	rows, err := s.db.QueryContext(ctx, `
WITH mapped AS (
  SELECT app_name, project_id, activity_id, COUNT(*) AS cnt
  FROM events
  WHERE project_id IS NOT NULL AND activity_id IS NOT NULL
  GROUP BY app_name, project_id, activity_id
), app_totals AS (
  SELECT app_name, SUM(cnt) AS total_cnt
  FROM mapped
  GROUP BY app_name
), top_map AS (
  SELECT m.*, ROW_NUMBER() OVER (PARTITION BY m.app_name ORDER BY m.cnt DESC) AS rn
  FROM mapped m
), unmapped AS (
  SELECT app_name, COUNT(*) AS impact_count, COALESCE(SUM(duration_ms), 0) AS impact_duration_ms
  FROM events
  `+where+`
  GROUP BY app_name
)
SELECT
  tm.app_name,
  tm.project_id,
  tm.activity_id,
  CAST(tm.cnt * 100.0 / NULLIF(app_tot.total_cnt, 0) AS INTEGER) AS confidence,
  u.impact_count,
  u.impact_duration_ms,
  tm.cnt,
  COALESCE(p.title, ''),
  COALESCE(a.title, '')
FROM top_map tm
JOIN app_totals app_tot ON app_tot.app_name = tm.app_name
JOIN unmapped u ON u.app_name = tm.app_name
LEFT JOIN projects p ON p.project_id = tm.project_id
LEFT JOIN activities a ON a.activity_id = tm.activity_id
WHERE tm.rn = 1 AND u.impact_count > 0
ORDER BY u.impact_duration_ms DESC
LIMIT ?
`, append(args, limit)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]domain.RuleSuggestion, 0)
	for rows.Next() {
		var item domain.RuleSuggestion
		var projectTitle, activityTitle string
		if err := rows.Scan(
			&item.AppPattern,
			&item.ProjectID,
			&item.ActivityID,
			&item.Confidence,
			&item.ImpactCount,
			&item.ImpactDurationMS,
			&item.EvidenceCount,
			&projectTitle,
			&activityTitle,
		); err != nil {
			return nil, err
		}
		item.SuggestionType = domain.SuggestionTypeAppOnly
		item.DisplayPath = buildPath(projectTitle, activityTitle)
		out = append(out, item)
	}
	return out, rows.Err()
}

func (s *Store) ListTitleSuggestions(ctx context.Context, q domain.SuggestionQuery) ([]domain.RuleSuggestion, error) {
	where := "WHERE project_id IS NULL AND activity_id IS NULL AND manually_mapped = false"
	args := make([]any, 0, 3)
	if q.MinDurationMS > 0 {
		where += " AND duration_ms >= ?"
		args = append(args, q.MinDurationMS)
	}
	if q.Date != nil && strings.TrimSpace(*q.Date) != "" {
		where += " AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?"
		args = append(args, *q.Date)
	}
	limit := q.Limit
	if limit <= 0 {
		limit = 50
	}

	rows, err := s.db.QueryContext(ctx, `
WITH mapped_title AS (
  SELECT app_name, window_title, project_id, activity_id, COUNT(*) AS cnt
  FROM events
  WHERE project_id IS NOT NULL AND activity_id IS NOT NULL AND window_title <> ''
  GROUP BY app_name, window_title, project_id, activity_id
), unmapped_title AS (
  SELECT app_name, window_title, COUNT(*) AS impact_count, COALESCE(SUM(duration_ms), 0) AS impact_duration_ms
  FROM events
  `+where+`
  GROUP BY app_name, window_title
)
SELECT
  m.app_name,
  m.window_title,
  m.project_id,
  m.activity_id,
  m.cnt,
  u.impact_count,
  u.impact_duration_ms,
  COALESCE(p.title, ''),
  COALESCE(a.title, '')
FROM mapped_title m
JOIN unmapped_title u ON u.app_name = m.app_name AND u.window_title = m.window_title
LEFT JOIN projects p ON p.project_id = m.project_id
LEFT JOIN activities a ON a.activity_id = m.activity_id
WHERE m.cnt >= 2 AND u.impact_count > 0
ORDER BY u.impact_duration_ms DESC
LIMIT ?
`, append(args, limit)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]domain.RuleSuggestion, 0)
	for rows.Next() {
		var item domain.RuleSuggestion
		var rawTitle string
		var projectTitle, activityTitle string
		if err := rows.Scan(
			&item.AppPattern,
			&rawTitle,
			&item.ProjectID,
			&item.ActivityID,
			&item.EvidenceCount,
			&item.ImpactCount,
			&item.ImpactDurationMS,
			&projectTitle,
			&activityTitle,
		); err != nil {
			return nil, err
		}
		pattern := domain.BuildTitlePattern(rawTitle)
		item.SuggestionType = domain.SuggestionTypeAppAndTitle
		item.TitlePattern = &pattern
		item.Confidence = 85
		item.DisplayPath = buildPath(projectTitle, activityTitle)
		out = append(out, item)
	}
	return out, rows.Err()
}

func buildPath(projectTitle, activityTitle string) string {
	parts := make([]string, 0, 2)
	if strings.TrimSpace(projectTitle) != "" {
		parts = append(parts, projectTitle)
	}
	if strings.TrimSpace(activityTitle) != "" {
		parts = append(parts, activityTitle)
	}
	if len(parts) == 0 {
		return "Unmapped"
	}
	return strings.Join(parts, " > ")
}

func (s *Store) ApplyEventMappings(ctx context.Context, updates []domain.EventMappingUpdate, manuallyMapped bool) (int64, error) {
	if len(updates) == 0 {
		return 0, nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()

	stmt, err := tx.PrepareContext(ctx, `
UPDATE events
SET project_id = ?, activity_id = ?, manually_mapped = ?
WHERE id = ? AND project_id IS NULL AND activity_id IS NULL
`)
	if err != nil {
		return 0, err
	}
	defer stmt.Close()

	var affected int64
	for _, update := range updates {
		res, err := stmt.ExecContext(ctx, update.ProjectID, update.ActivityID, manuallyMapped, update.EventID)
		if err != nil {
			return affected, err
		}
		n, _ := res.RowsAffected()
		affected += n
	}
	if err := tx.Commit(); err != nil {
		return affected, err
	}
	return affected, nil
}

func (s *Store) CurrentProjectID(ctx context.Context) (*int64, error) {
	var id int64
	err := s.db.QueryRowContext(ctx, `
SELECT pa.project_id
FROM project_assignments pa
WHERE pa.ended_at IS NULL
ORDER BY pa.started_at DESC
LIMIT 1
`).Scan(&id)
	if err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	return &id, nil
}

func (s *Store) FindProjectIDByTitle(ctx context.Context, title string) (*int64, error) {
	var id int64
	err := s.db.QueryRowContext(ctx, `
SELECT project_id
FROM projects
WHERE LOWER(title) = LOWER(?)
ORDER BY project_id ASC
LIMIT 1
`, strings.TrimSpace(title)).Scan(&id)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &id, nil
}

func (s *Store) FindActivityIDByTitle(ctx context.Context, projectID int64, title string) (*int64, error) {
	var id int64
	err := s.db.QueryRowContext(ctx, `
SELECT activity_id
FROM activities
WHERE project_id = ? AND LOWER(title) = LOWER(?)
ORDER BY activity_id ASC
LIMIT 1
`, projectID, strings.TrimSpace(title)).Scan(&id)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &id, nil
}

func (s *Store) ListReportEvents(ctx context.Context, rangeKey string, date *string) ([]domain.Event, error) {
	where, args := rangeFilter(rangeKey, date)
	query := `
SELECT
  e.id,
  e.timestamp_ms,
  e.duration_ms,
  e.app_name,
  e.window_title,
  e.project_id,
  e.activity_id,
  COALESCE(p.title, '') AS project_title
FROM events e
LEFT JOIN projects p ON p.project_id = e.project_id
` + where + `
ORDER BY e.timestamp_ms ASC
`
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]domain.Event, 0)
	for rows.Next() {
		var event domain.Event
		if err := rows.Scan(&event.ID, &event.TimestampMS, &event.DurationMS, &event.AppName, &event.WindowTitle, &event.ProjectID, &event.ActivityID, &event.ProjectTitle); err != nil {
			return nil, err
		}
		out = append(out, event)
	}
	return out, rows.Err()
}

func rangeFilter(rangeKey string, date *string) (string, []any) {
	if date != nil && strings.TrimSpace(*date) != "" {
		return `WHERE DATE(TO_TIMESTAMP(e.timestamp_ms / 1000)) = ?`, []any{strings.TrimSpace(*date)}
	}

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
SELECT p.project_id, p.title, COALESCE(p.metadata, '')
FROM project_assignments pa
JOIN projects p ON p.project_id = pa.project_id
WHERE pa.ended_at IS NULL
ORDER BY pa.started_at DESC
`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]domain.Project, 0)
	for rows.Next() {
		var project domain.Project
		if err := rows.Scan(&project.ProjectID, &project.Title, &project.Metadata); err != nil {
			return nil, err
		}
		out = append(out, project)
	}
	return out, rows.Err()
}

func (s *Store) ListAllProjects(ctx context.Context) ([]domain.Project, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT project_id, title, COALESCE(metadata, '')
FROM projects
ORDER BY title
`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]domain.Project, 0)
	for rows.Next() {
		var project domain.Project
		if err := rows.Scan(&project.ProjectID, &project.Title, &project.Metadata); err != nil {
			return nil, err
		}
		out = append(out, project)
	}
	return out, rows.Err()
}

func (s *Store) ListActivitiesByProject(ctx context.Context, projectID int64) ([]domain.Activity, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT activity_id, project_id, title
FROM activities
WHERE project_id = ?
ORDER BY title ASC, activity_id ASC
`, projectID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]domain.Activity, 0)
	for rows.Next() {
		var activity domain.Activity
		if err := rows.Scan(&activity.ActivityID, &activity.ProjectID, &activity.Title); err != nil {
			return nil, err
		}
		out = append(out, activity)
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
	var title string
	err := s.db.QueryRowContext(ctx, `
SELECT pa.project_id, p.title
FROM project_assignments pa
JOIN projects p ON p.project_id = pa.project_id
WHERE pa.ended_at IS NULL
ORDER BY pa.started_at DESC
LIMIT 1
`).Scan(&id, &title)
	if err != nil {
		if err == sql.ErrNoRows {
			return "None", nil, nil
		}
		return "", nil, err
	}
	return title, &id, nil
}

func (s *Store) ListUnmappedDates(ctx context.Context, minDurationMS int64) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT DISTINCT CAST(DATE(TO_TIMESTAMP(timestamp_ms / 1000)) AS VARCHAR)
FROM events
WHERE project_id IS NULL AND activity_id IS NULL AND manually_mapped = false AND duration_ms >= ?
ORDER BY 1 DESC
`, minDurationMS)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]string, 0)
	for rows.Next() {
		var value string
		if err := rows.Scan(&value); err != nil {
			return nil, err
		}
		out = append(out, value)
	}
	return out, rows.Err()
}

func (s *Store) ListGroupedUnmappedEvents(ctx context.Context, date string, minDurationMS int64) ([]domain.GroupedEvent, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT app_name, window_title, COALESCE(SUM(duration_ms), 0), COUNT(*)
FROM events
WHERE project_id IS NULL AND activity_id IS NULL AND manually_mapped = false
  AND duration_ms >= ?
  AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
GROUP BY app_name, window_title
ORDER BY 3 DESC
`, minDurationMS, date)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]domain.GroupedEvent, 0)
	for rows.Next() {
		var event domain.GroupedEvent
		if err := rows.Scan(&event.AppName, &event.WindowTitle, &event.TotalDurationMS, &event.EventCount); err != nil {
			return nil, err
		}
		out = append(out, event)
	}
	return out, rows.Err()
}

func (s *Store) MapEventsByGroup(ctx context.Context, date, appName, windowTitle string, projectID, activityID int64) (int64, error) {
	res, err := s.db.ExecContext(ctx, `
UPDATE events
SET project_id = ?, activity_id = ?, manually_mapped = true
WHERE project_id IS NULL AND activity_id IS NULL AND manually_mapped = false
  AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
  AND app_name = ? AND window_title = ?
`, projectID, activityID, date, appName, windowTitle)
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
WHERE project_id IS NULL AND activity_id IS NULL AND manually_mapped = false
  AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
  AND app_name = ? AND window_title = ?
`, date, appName, windowTitle)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return n, nil
}

func (s *Store) UpsertImportedProject(ctx context.Context, in domain.ImportedProjectUpsert) (domain.ImportedProjectUpsertResult, error) {
	var (
		projectID int64
		title     string
		metadata  string
	)
	err := s.db.QueryRowContext(ctx, `
SELECT project_id, title, metadata
FROM projects
WHERE source = ? AND external_variant_key = ?
LIMIT 1
`, in.Source, in.ExternalVariantKey).Scan(&projectID, &title, &metadata)
	if err == sql.ErrNoRows {
		if legacyPhaseID, ok := parseLegacyVariantPhaseID(in.ExternalVariantKey); ok {
			err = s.db.QueryRowContext(ctx, `
SELECT project_id, title, metadata
FROM projects
WHERE source = ?
  AND external_variant_key IS NULL
  AND external_customer_id = ?
  AND external_project_id = ?
  AND external_phase_id = ?
LIMIT 1
`, in.Source, in.ExternalCustomerID, in.ExternalProjectID, legacyPhaseID).Scan(&projectID, &title, &metadata)
		}
	}
	if err != nil {
		if err != sql.ErrNoRows {
			return domain.ImportedProjectUpsertResult{}, err
		}
		nextID, err := s.nextProjectID(ctx)
		if err != nil {
			return domain.ImportedProjectUpsertResult{}, err
		}
		res, err := s.db.ExecContext(ctx, `
INSERT INTO projects (
  project_id, customer_id, name, title, metadata, source, external_customer_id, external_project_id, external_variant_key
) VALUES (?, 0, ?, ?, ?, ?, ?, ?, ?)
`, nextID, in.Title, in.Title, in.Metadata, in.Source, in.ExternalCustomerID, in.ExternalProjectID, in.ExternalVariantKey)
		if err != nil {
			return domain.ImportedProjectUpsertResult{}, err
		}
		insertedID, _ := res.LastInsertId()
		if insertedID <= 0 {
			insertedID = nextID
		}
		return domain.ImportedProjectUpsertResult{ProjectID: insertedID, Created: true, Updated: false}, nil
	}

	updated := false
	if title != in.Title || metadata != in.Metadata {
		if _, err := s.db.ExecContext(ctx, `UPDATE projects SET title = ?, metadata = ? WHERE project_id = ?`, in.Title, in.Metadata, projectID); err != nil {
			return domain.ImportedProjectUpsertResult{}, err
		}
		updated = true
	}
	return domain.ImportedProjectUpsertResult{ProjectID: projectID, Created: false, Updated: updated}, nil
}

func (s *Store) SyncImportedActivities(ctx context.Context, projectID int64, activities []domain.ImportedActivityUpsert) (domain.ImportedActivitySyncResult, error) {
	const source = "tidsreg"
	externalIDs := make([]int64, 0, len(activities))
	seenExternal := make(map[int64]struct{}, len(activities))
	result := domain.ImportedActivitySyncResult{}

	for _, activity := range activities {
		if activity.ExternalActivityID <= 0 {
			continue
		}
		if _, ok := seenExternal[activity.ExternalActivityID]; ok {
			continue
		}
		seenExternal[activity.ExternalActivityID] = struct{}{}
		externalIDs = append(externalIDs, activity.ExternalActivityID)

		var (
			activityID int64
			title      string
		)
		err := s.db.QueryRowContext(ctx, `
SELECT activity_id, title
FROM activities
WHERE source = ? AND project_id = ? AND external_activity_id = ?
LIMIT 1
`, source, projectID, activity.ExternalActivityID).Scan(&activityID, &title)
		if err == nil {
			if strings.TrimSpace(title) != strings.TrimSpace(activity.Title) {
				if _, err := s.db.ExecContext(ctx, `UPDATE activities SET title = ? WHERE activity_id = ?`, activity.Title, activityID); err != nil {
					return result, err
				}
				result.Updated++
			}
			continue
		}
		if err != sql.ErrNoRows {
			return result, err
		}
		nextID, err := s.nextActivityID(ctx)
		if err != nil {
			return result, err
		}

		if _, err := s.db.ExecContext(ctx, `
INSERT INTO activities (
  activity_id, project_id, name, title, source, external_activity_id
) VALUES (?, ?, ?, ?, ?, ?)
`, nextID, projectID, activity.Title, activity.Title, source, activity.ExternalActivityID); err != nil {
			return result, err
		}
		result.Created++
	}

	deleteQuery := `
DELETE FROM activities
WHERE project_id = ? AND source = ?
  AND NOT EXISTS (SELECT 1 FROM mapping_rules mr WHERE mr.activity_id = activities.activity_id)
`
	deleteArgs := make([]any, 0, 2+len(externalIDs))
	deleteArgs = append(deleteArgs, projectID, source)
	if len(externalIDs) > 0 {
		placeholders := make([]string, 0, len(externalIDs))
		for _, id := range externalIDs {
			placeholders = append(placeholders, "?")
			deleteArgs = append(deleteArgs, id)
		}
		deleteQuery += ` AND external_activity_id NOT IN (` + strings.Join(placeholders, ",") + `)`
	}
	delRes, err := s.db.ExecContext(ctx, deleteQuery, deleteArgs...)
	if err != nil {
		return result, err
	}
	deleted, _ := delRes.RowsAffected()
	result.Deleted = int(deleted)
	return result, nil
}

func (s *Store) convertLegacyGlobRules(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, `
SELECT id, COALESCE(app_pattern, ''), COALESCE(title_pattern, '')
FROM mapping_rules
WHERE COALESCE(pattern_format, 'glob') <> 'regex'
`)
	if err != nil {
		return err
	}
	defer rows.Close()

	type legacyRule struct {
		id    int64
		app   string
		title string
	}
	legacy := make([]legacyRule, 0)
	for rows.Next() {
		var item legacyRule
		if err := rows.Scan(&item.id, &item.app, &item.title); err != nil {
			return err
		}
		legacy = append(legacy, item)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if len(legacy) == 0 {
		return nil
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	for _, item := range legacy {
		_, err := tx.ExecContext(ctx, `
UPDATE mapping_rules
SET app_pattern = ?, title_pattern = ?, pattern_format = 'regex'
WHERE id = ?
`, domain.GlobToRegexPattern(item.app), domain.GlobToRegexPattern(item.title), item.id)
		if err != nil {
			return err
		}
	}

	return tx.Commit()
}

func nullIfEmpty(value string) any {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil
	}
	return value
}

func parseLegacyVariantPhaseID(value string) (int64, bool) {
	parts := strings.Split(strings.TrimSpace(value), ":")
	if len(parts) != 3 {
		return 0, false
	}
	phaseID, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil {
		return 0, false
	}
	return phaseID, true
}

func nullStringValue(value sql.NullString) string {
	if !value.Valid {
		return ""
	}
	return strings.TrimSpace(value.String)
}

func nullInt64Ptr(value sql.NullInt64) *int64 {
	if !value.Valid {
		return nil
	}
	copyValue := value.Int64
	return &copyValue
}

func orDefaultSource(source domain.RuleSource) domain.RuleSource {
	if source == "" {
		return domain.RuleSourceUser
	}
	return source
}

func (s *Store) nextProjectID(ctx context.Context) (int64, error) {
	var id int64
	if err := s.db.QueryRowContext(ctx, `SELECT COALESCE(MAX(project_id), 0) + 1 FROM projects`).Scan(&id); err != nil {
		return 0, err
	}
	return id, nil
}

func (s *Store) nextActivityID(ctx context.Context) (int64, error) {
	var id int64
	if err := s.db.QueryRowContext(ctx, `SELECT COALESCE(MAX(activity_id), 0) + 1 FROM activities`).Scan(&id); err != nil {
		return 0, err
	}
	return id, nil
}

func (s *Store) String() string { return fmt.Sprintf("duckdb-store(%p)", s.db) }

var (
	_ interface{ Close() error } = (*Store)(nil)
)
