package duckdb

import (
	"context"
	"testing"

	"time-tracker/internal/domain"
)

func openTestStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(":memory:")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	return s
}

func seedProjectActivity(t *testing.T, s *Store) {
	t.Helper()
	ctx := context.Background()
	queries := []string{
		"INSERT INTO projects (project_id, title, metadata) VALUES (10, 'web-app', 'notes')",
		"INSERT INTO activities (activity_id, project_id, title) VALUES (100, 10, 'development')",
		"INSERT INTO activities (activity_id, project_id, title) VALUES (101, 10, 'meeting')",
	}
	for _, q := range queries {
		if _, err := s.db.ExecContext(ctx, q); err != nil {
			t.Fatalf("seed query failed: %v", err)
		}
	}
}

func TestListAppSuggestionsReturnsProjectActivityTarget(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	seedProjectActivity(t, s)
	ctx := context.Background()

	for i := 0; i < 5; i++ {
		if _, err := s.db.ExecContext(ctx, `INSERT INTO events (timestamp_ms, app_name, window_title, duration_ms, project_id, activity_id, manually_mapped) VALUES (?, 'Code', 'main.go', 60000, 10, 100, true)`, int64(i+1)); err != nil {
			t.Fatalf("insert mapped event: %v", err)
		}
	}
	for i := 0; i < 3; i++ {
		if _, err := s.db.ExecContext(ctx, `INSERT INTO events (timestamp_ms, app_name, window_title, duration_ms, manually_mapped) VALUES (?, 'Code', 'new file', 45000, false)`, int64(100+i)); err != nil {
			t.Fatalf("insert unmapped event: %v", err)
		}
	}

	suggestions, err := s.ListAppSuggestions(ctx, domain.SuggestionQuery{Limit: 10, MinDurationMS: 1000})
	if err != nil {
		t.Fatalf("list app suggestions: %v", err)
	}
	if len(suggestions) == 0 {
		t.Fatalf("expected suggestions")
	}
	if suggestions[0].AppPattern != "Code" {
		t.Fatalf("expected app pattern Code, got %s", suggestions[0].AppPattern)
	}
	if suggestions[0].ProjectID != 10 || suggestions[0].ActivityID != 100 {
		t.Fatalf("expected target project/activity 10/100, got %d/%d", suggestions[0].ProjectID, suggestions[0].ActivityID)
	}
}

func TestApplyEventMappingsUpdatesEvents(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	seedProjectActivity(t, s)
	ctx := context.Background()

	if _, err := s.db.ExecContext(ctx, `INSERT INTO events (id, timestamp_ms, app_name, window_title, duration_ms, manually_mapped) VALUES (1, 100, 'Slack', 'daily standup', 60000, false)`); err != nil {
		t.Fatalf("insert event: %v", err)
	}

	n, err := s.ApplyEventMappings(ctx, []domain.EventMappingUpdate{{
		EventID:    1,
		ProjectID:  10,
		ActivityID: 101,
	}}, true)
	if err != nil {
		t.Fatalf("apply event mappings: %v", err)
	}
	if n != 1 {
		t.Fatalf("expected 1 updated row, got %d", n)
	}

	var projectID, activityID int64
	var manual bool
	if err := s.db.QueryRowContext(ctx, `SELECT project_id, activity_id, manually_mapped FROM events WHERE id = 1`).Scan(&projectID, &activityID, &manual); err != nil {
		t.Fatalf("query event: %v", err)
	}
	if projectID != 10 || activityID != 101 || !manual {
		t.Fatalf("unexpected event mapping project=%d activity=%d manual=%v", projectID, activityID, manual)
	}
}
