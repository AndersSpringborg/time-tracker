package duckdb

import (
	"context"
	"path/filepath"
	"testing"
)

// seedRetentionEvents inserts events on a given day, returning their total.
func seedRetentionEvents(t *testing.T, s *Store, day string, rows []retentionRow) int64 {
	t.Helper()
	var total int64
	for i, row := range rows {
		_, err := s.db.Exec(`
			INSERT INTO events (timestamp_ms, app_name, window_title, duration_ms, wifi_ssid, project_id, activity_id, manually_mapped)
			VALUES (epoch_ms(strptime(?, '%Y-%m-%d')) + ?, ?, ?, ?, ?, ?, ?, ?)`,
			day, int64(i)*1000, row.app, row.title, row.durationMS, row.wifi,
			nullableID(row.projectID), nullableID(row.activityID), row.projectID != 0)
		if err != nil {
			t.Fatal(err)
		}
		total += row.durationMS
	}
	return total
}

type retentionRow struct {
	app, title, wifi string
	durationMS       int64
	projectID        int64
	activityID       int64
}

func nullableID(id int64) any {
	if id == 0 {
		return nil
	}
	return id
}

func dayTotals(t *testing.T, s *Store, day string) (int64, int64) {
	t.Helper()
	var events, total int64
	err := s.db.QueryRow(`
		SELECT count(*), coalesce(sum(duration_ms), 0) FROM events
		WHERE strftime(to_timestamp(timestamp_ms / 1000), '%Y-%m-%d') = ?`, day).Scan(&events, &total)
	if err != nil {
		t.Fatal(err)
	}
	return events, total
}

func TestSummarizeDayPreservesTotalsAndRemovesDetail(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	seedProjectActivity(t, store)
	total := seedRetentionEvents(t, store, "2026-03-02", []retentionRow{
		{app: "Editor", title: "a.go", wifi: "Office", durationMS: 60000, projectID: 1, activityID: 1},
		{app: "Editor", title: "b.go", wifi: "Office", durationMS: 30000, projectID: 1, activityID: 1},
		{app: "Browser", title: "docs", wifi: "Home", durationMS: 15000},
	})

	summary, err := store.SummarizeDay(context.Background(), "2026-03-02")
	if err != nil {
		t.Fatal(err)
	}
	if summary.TotalMS != total || summary.EventCount != 3 {
		t.Fatalf("summary %+v; want total %d over 3 events", summary, total)
	}

	events, remaining := dayTotals(t, store, "2026-03-02")
	if events != 0 || remaining != 0 {
		t.Fatalf("detail not removed: %d events, %d ms", events, remaining)
	}

	// The summary keeps the mapped and unmapped time apart, and keeps the wifi
	// dimension so work classification can still be recomputed.
	rows, err := store.db.Query(`SELECT project_id, activity_id, app_name, wifi_ssid, total_ms, event_count
		FROM daily_summaries WHERE day = DATE '2026-03-02' ORDER BY app_name`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var summarized, summarizedMS int64
	var wifis []string
	for rows.Next() {
		var projectID, activityID, totalMS, count int64
		var app, wifi string
		if err := rows.Scan(&projectID, &activityID, &app, &wifi, &totalMS, &count); err != nil {
			t.Fatal(err)
		}
		summarized += count
		summarizedMS += totalMS
		wifis = append(wifis, wifi)
	}
	if summarized != 3 || summarizedMS != total {
		t.Fatalf("summary rows hold %d events / %d ms; want 3 / %d", summarized, summarizedMS, total)
	}
	if len(wifis) != 2 {
		t.Fatalf("expected the wifi dimension to be preserved, got %v", wifis)
	}
}

func TestSummarizeDayIsRetrySafe(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	total := seedRetentionEvents(t, store, "2026-03-03", []retentionRow{
		{app: "Editor", title: "a.go", wifi: "Office", durationMS: 60000},
	})

	first, err := store.SummarizeDay(context.Background(), "2026-03-03")
	if err != nil {
		t.Fatal(err)
	}
	second, err := store.SummarizeDay(context.Background(), "2026-03-03")
	if err != nil {
		t.Fatal(err)
	}
	if second.EventCount != 0 {
		t.Fatalf("a re-run summarised %d events again", second.EventCount)
	}

	var totalMS, coverageMS int64
	if err := store.db.QueryRow(`SELECT coalesce(sum(total_ms), 0) FROM daily_summaries WHERE day = DATE '2026-03-03'`).
		Scan(&totalMS); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRow(`SELECT total_ms FROM summary_coverage WHERE day = DATE '2026-03-03'`).
		Scan(&coverageMS); err != nil {
		t.Fatal(err)
	}
	if totalMS != total || coverageMS != first.TotalMS {
		t.Fatalf("retry changed totals: summaries=%d coverage=%d want %d", totalMS, coverageMS, total)
	}
}

func TestSummarizeDayLeavesOtherDaysAndIngestionCursorsAlone(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tracker.db")
	store, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	seedRetentionEvents(t, store, "2026-03-04", []retentionRow{{app: "Editor", title: "a", durationMS: 1000}})
	keptTotal := seedRetentionEvents(t, store, "2026-03-05", []retentionRow{{app: "Editor", title: "b", durationMS: 2000}})
	if _, err := store.db.Exec(
		`INSERT INTO ingestion_producers (producer_id, acknowledged_sequence) VALUES ('client', 42)`); err != nil {
		t.Fatal(err)
	}

	if _, err := store.SummarizeDay(context.Background(), "2026-03-04"); err != nil {
		t.Fatal(err)
	}

	events, total := dayTotals(t, store, "2026-03-05")
	if events != 1 || total != keptTotal {
		t.Fatalf("neighbouring day changed: %d events, %d ms", events, total)
	}
	var sequence int64
	if err := store.db.QueryRow(`SELECT acknowledged_sequence FROM ingestion_producers WHERE producer_id = 'client'`).
		Scan(&sequence); err != nil {
		t.Fatal(err)
	}
	if sequence != 42 {
		t.Fatalf("ingestion cursor changed to %d; replay protection must outlive deleted events", sequence)
	}
}

func TestSummarizeDayRefusesTheCurrentDay(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	var today string
	if err := store.db.QueryRow(`SELECT strftime(current_date, '%Y-%m-%d')`).Scan(&today); err != nil {
		t.Fatal(err)
	}
	seedRetentionEvents(t, store, today, []retentionRow{{app: "Editor", title: "a", durationMS: 1000}})

	if _, err := store.SummarizeDay(context.Background(), today); err == nil {
		t.Fatal("summarising a day that is still accumulating must be refused")
	}
	events, _ := dayTotals(t, store, today)
	if events != 1 {
		t.Fatal("today's detail must be left alone")
	}
}

func TestRetentionDaysReportOldestFirstExcludingToday(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	seedProjectActivity(t, store)
	seedRetentionEvents(t, store, "2026-03-07", []retentionRow{
		{app: "Editor", title: "a.go", wifi: "Office", durationMS: 1000, projectID: 1, activityID: 1},
		{app: "Browser", title: "docs", wifi: "Home", durationMS: 2000},
	})
	seedRetentionEvents(t, store, "2026-03-06", []retentionRow{{app: "Editor", title: "b.go", durationMS: 3000}})
	var today string
	if err := store.db.QueryRow(`SELECT strftime(current_date, '%Y-%m-%d')`).Scan(&today); err != nil {
		t.Fatal(err)
	}
	seedRetentionEvents(t, store, today, []retentionRow{{app: "Editor", title: "now.go", durationMS: 9000}})

	days, err := store.RetentionDays(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(days) != 2 {
		t.Fatalf("expected the two past days only, got %+v", days)
	}
	if days[0].Day != "2026-03-06" {
		t.Fatalf("days must be oldest first, got %+v", days)
	}
	if days[1].Events != 2 || days[1].TotalMS != 3000 {
		t.Fatalf("unexpected totals: %+v", days[1])
	}
	if days[1].UnmappedEvents != 1 {
		t.Fatalf("unmapped events must be reported so lost review work is visible: %+v", days[1])
	}
	if days[1].EstimatedBytes <= 0 {
		t.Fatalf("estimated bytes missing: %+v", days[1])
	}
}

func TestDetailBytesShrinksAfterSummarizing(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	seedRetentionEvents(t, store, "2026-03-08", []retentionRow{{app: "Editor", title: "a-long-window-title", durationMS: 1000}})
	before, err := store.DetailBytes(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if before <= 0 {
		t.Fatalf("detail bytes should be positive, got %d", before)
	}

	if _, err := store.SummarizeDay(context.Background(), "2026-03-08"); err != nil {
		t.Fatal(err)
	}
	after, err := store.DetailBytes(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if after >= before {
		t.Fatalf("detail bytes did not shrink: %d -> %d", before, after)
	}
}
