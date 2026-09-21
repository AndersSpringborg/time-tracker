package duckdb

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"time-tracker/internal/domain"
)

// SummarizeDay folds one day of raw events into daily_summaries and deletes the
// detail, in a single transaction: a day is never readable from both sources.
// Totals, per-project/activity/app/wifi breakdowns and event counts survive;
// window titles, timelines and per-event review do not.
func (s *Store) SummarizeDay(ctx context.Context, day string) (domain.DaySummary, error) {
	s.ingestionMu.Lock()
	defer s.ingestionMu.Unlock()

	summary := domain.DaySummary{Day: day}
	if err := s.refuseCurrentDay(ctx, day); err != nil {
		return summary, err
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return summary, fmt.Errorf("begin summarize: %w", err)
	}
	defer tx.Rollback()

	if err := tx.QueryRowContext(ctx, `
		SELECT count(*), coalesce(sum(duration_ms), 0) FROM events
		WHERE strftime(to_timestamp(timestamp_ms / 1000), '%Y-%m-%d') = ?`, day).
		Scan(&summary.EventCount, &summary.TotalMS); err != nil {
		return summary, fmt.Errorf("measure %s: %w", day, err)
	}
	if summary.EventCount == 0 {
		// Already summarised, or nothing recorded: either way there is no
		// detail left to fold in, so the existing coverage row stands.
		return summary, tx.Commit()
	}

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO daily_summaries (day, project_id, activity_id, app_name, wifi_ssid, total_ms, event_count)
		SELECT to_timestamp(timestamp_ms / 1000)::DATE,
		       coalesce(project_id, 0), coalesce(activity_id, 0), app_name, coalesce(wifi_ssid, ''),
		       sum(duration_ms), count(*)
		FROM events
		WHERE strftime(to_timestamp(timestamp_ms / 1000), '%Y-%m-%d') = ?
		GROUP BY 1, 2, 3, 4, 5
		ON CONFLICT (day, project_id, activity_id, app_name, wifi_ssid) DO UPDATE SET
		       total_ms = daily_summaries.total_ms + excluded.total_ms,
		       event_count = daily_summaries.event_count + excluded.event_count`, day); err != nil {
		return summary, fmt.Errorf("write summary for %s: %w", day, err)
	}

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO summary_coverage (day, detail_deleted, event_count, total_ms)
		VALUES (strptime(?, '%Y-%m-%d')::DATE, true, ?, ?)
		ON CONFLICT (day) DO UPDATE SET
		       detail_deleted = true,
		       summarized_at = now(),
		       event_count = summary_coverage.event_count + excluded.event_count,
		       total_ms = summary_coverage.total_ms + excluded.total_ms`,
		day, summary.EventCount, summary.TotalMS); err != nil {
		return summary, fmt.Errorf("record coverage for %s: %w", day, err)
	}

	if _, err := tx.ExecContext(ctx, `
		DELETE FROM events WHERE strftime(to_timestamp(timestamp_ms / 1000), '%Y-%m-%d') = ?`, day); err != nil {
		return summary, fmt.Errorf("delete detail for %s: %w", day, err)
	}
	// Ingestion cursors live in their own table and are deliberately untouched,
	// so a replayed batch cannot recreate history that was just summarised.
	return summary, tx.Commit()
}

var errCurrentDay = errors.New("refusing to summarize a day that is still being recorded")

func (s *Store) refuseCurrentDay(ctx context.Context, day string) error {
	var isCurrent bool
	err := s.db.QueryRowContext(ctx, `SELECT strptime(?, '%Y-%m-%d')::DATE >= current_date`, day).Scan(&isCurrent)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("parse day %q", day)
		}
		return fmt.Errorf("check day %q: %w", day, err)
	}
	if isCurrent {
		return fmt.Errorf("%w: %s", errCurrentDay, day)
	}
	return nil
}

// DetailBytes estimates the bytes of raw event detail held in the database.
// It measures data, not the file: DuckDB's file is larger and is reclaimed by
// compaction, not by deleting rows.
func (s *Store) DetailBytes(ctx context.Context) (int64, error) {
	var rows, textBytes int64
	err := s.db.QueryRowContext(ctx, `
		SELECT count(*),
		       coalesce(sum(length(app_name) + length(window_title) + length(coalesce(wifi_ssid, ''))), 0)
		FROM events`).Scan(&rows, &textBytes)
	if err != nil {
		return 0, fmt.Errorf("measure detail: %w", err)
	}
	return rows*bytesPerEventRow + textBytes, nil
}

// RetentionDays lists days holding detail, oldest first. The current day is
// excluded because it is still being recorded.
func (s *Store) RetentionDays(ctx context.Context) ([]domain.RetentionDay, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT strftime(to_timestamp(timestamp_ms / 1000), '%Y-%m-%d') AS day,
		       count(*),
		       coalesce(sum(duration_ms), 0),
		       count(*) * ? + coalesce(sum(length(app_name) + length(window_title) + length(coalesce(wifi_ssid, ''))), 0),
		       count(*) FILTER (WHERE project_id IS NULL AND activity_id IS NULL AND NOT manually_mapped)
		FROM events
		WHERE to_timestamp(timestamp_ms / 1000)::DATE < current_date
		GROUP BY 1
		ORDER BY 1`, bytesPerEventRow)
	if err != nil {
		return nil, fmt.Errorf("list retention days: %w", err)
	}
	defer rows.Close()

	var days []domain.RetentionDay
	for rows.Next() {
		var day domain.RetentionDay
		if err := rows.Scan(&day.Day, &day.Events, &day.TotalMS, &day.EstimatedBytes, &day.UnmappedEvents); err != nil {
			return nil, err
		}
		days = append(days, day)
	}
	return days, rows.Err()
}

// summaryRangeFilter mirrors rangeFilter, expressed against the summary day
// instead of an event timestamp, so both sources cover the same range.
func summaryRangeFilter(rangeKey string, date *string) (string, []any) {
	if date != nil && strings.TrimSpace(*date) != "" {
		return `WHERE s.day = strptime(?, '%Y-%m-%d')::DATE`, []any{strings.TrimSpace(*date)}
	}
	switch rangeKey {
	case "week":
		return `WHERE s.day >= current_date - INTERVAL 7 DAY`, nil
	case "all":
		return ``, nil
	default:
		return `WHERE s.day >= current_date`, nil
	}
}

// ListSummaryContributions returns summarised time for days in range whose
// detail has been deleted. Days that still hold events are excluded, so no day
// is ever counted from both sources.
func (s *Store) ListSummaryContributions(ctx context.Context, rangeKey string, date *string) ([]domain.SummaryContribution, error) {
	where, args := summaryRangeFilter(rangeKey, date)
	if where == "" {
		where = `WHERE true`
	}
	query := `
		SELECT strftime(s.day, '%Y-%m-%d'), coalesce(p.title, ''), coalesce(a.title, ''),
		       s.app_name, s.wifi_ssid, s.total_ms, s.event_count
		FROM daily_summaries s
		JOIN summary_coverage c ON c.day = s.day AND c.detail_deleted
		LEFT JOIN projects p ON p.project_id = s.project_id
		LEFT JOIN activities a ON a.activity_id = s.activity_id
		` + where + `
		ORDER BY s.day, s.app_name`
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("list summary contributions: %w", err)
	}
	defer rows.Close()

	var contributions []domain.SummaryContribution
	for rows.Next() {
		var c domain.SummaryContribution
		if err := rows.Scan(&c.Day, &c.ProjectTitle, &c.ActivityName, &c.AppName, &c.WifiSSID, &c.TotalMS, &c.EventCount); err != nil {
			return nil, err
		}
		contributions = append(contributions, c)
	}
	return contributions, rows.Err()
}

// SummarizedDays lists days in range that can no longer be shown in detail.
func (s *Store) SummarizedDays(ctx context.Context, rangeKey string, date *string) ([]string, error) {
	where, args := summaryRangeFilter(rangeKey, date)
	if where == "" {
		where = `WHERE true`
	}
	query := `SELECT strftime(s.day, '%Y-%m-%d') FROM summary_coverage s ` + where +
		` AND s.detail_deleted ORDER BY s.day`
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("list summarized days: %w", err)
	}
	defer rows.Close()

	var days []string
	for rows.Next() {
		var day string
		if err := rows.Scan(&day); err != nil {
			return nil, err
		}
		days = append(days, day)
	}
	return days, rows.Err()
}
