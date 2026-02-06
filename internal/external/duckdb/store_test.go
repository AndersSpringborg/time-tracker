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

func seedHierarchy(t *testing.T, s *Store) {
	t.Helper()
	ctx := context.Background()
	queries := []string{
		"INSERT INTO customers (customer_id, name) VALUES (1, 'Acme')",
		"INSERT INTO projects (project_id, customer_id, name) VALUES (10, 1, 'Platform')",
		"INSERT INTO phases (phase_id, project_id, name) VALUES (100, 10, 'Build')",
		"INSERT INTO activities (activity_id, phase_id, name) VALUES (1000, 100, 'Coding')",
		"INSERT INTO kinds (activity_id, kind_id, name, billable) VALUES (1000, 10000, 'Feature', true)",
	}
	for _, q := range queries {
		if _, err := s.db.ExecContext(ctx, q); err != nil {
			t.Fatalf("seed query failed: %v", err)
		}
	}
}

func TestAnalyzeSuggestionsReturnsAppSuggestion(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	seedHierarchy(t, s)
	ctx := context.Background()

	for i := 0; i < 5; i++ {
		if _, err := s.db.ExecContext(ctx, `INSERT INTO events (timestamp_ms, app_name, window_title, duration_ms, activity_id, kind_id, manually_mapped) VALUES (?, 'Code', 'main.go', 60000, 1000, 10000, true)`, int64(i+1)); err != nil {
			t.Fatalf("insert mapped event: %v", err)
		}
	}
	for i := 0; i < 3; i++ {
		if _, err := s.db.ExecContext(ctx, `INSERT INTO events (timestamp_ms, app_name, window_title, duration_ms, manually_mapped) VALUES (?, 'Code', 'new file', 45000, false)`, int64(100+i)); err != nil {
			t.Fatalf("insert unmapped event: %v", err)
		}
	}

	suggestions, err := s.AnalyzeSuggestions(ctx, domain.SuggestionQuery{Limit: 10, MinDurationMS: 1000})
	if err != nil {
		t.Fatalf("analyze suggestions: %v", err)
	}
	if len(suggestions) == 0 {
		t.Fatalf("expected suggestions")
	}
	if suggestions[0].AppPattern != "Code" {
		t.Fatalf("expected app pattern Code, got %s", suggestions[0].AppPattern)
	}
}

func TestAcceptSuggestionCreatesRuleAndMaps(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	seedHierarchy(t, s)
	ctx := context.Background()

	for i := 0; i < 2; i++ {
		if _, err := s.db.ExecContext(ctx, `INSERT INTO events (timestamp_ms, app_name, window_title, duration_ms, manually_mapped) VALUES (?, 'Slack', 'daily standup', 60000, false)`, int64(100+i)); err != nil {
			t.Fatalf("insert unmapped event: %v", err)
		}
	}

	title := "*standup*"
	res, err := s.AcceptSuggestion(ctx, domain.ApplySuggestionInput{
		Suggestion: domain.RuleSuggestion{
			SuggestionType: domain.SuggestionTypeAppAndTitle,
			AppPattern:     "Slack",
			TitlePattern:   &title,
			ActivityID:     1000,
			KindID:         10000,
		},
		ApplyNow: true,
	})
	if err != nil {
		t.Fatalf("accept suggestion: %v", err)
	}
	if !res.RuleCreated {
		t.Fatalf("expected rule to be created")
	}
	if res.MappedEvents != 2 {
		t.Fatalf("expected 2 mapped events, got %d", res.MappedEvents)
	}
}
