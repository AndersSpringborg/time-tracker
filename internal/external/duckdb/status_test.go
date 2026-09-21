package duckdb

import (
	"context"
	"testing"
)

func TestUnmappedEventCountCountsOnlyUnmappedEvents(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	seedProjectActivity(t, s)
	ctx := context.Background()

	inserts := []string{
		// Two events nothing has claimed.
		"INSERT INTO events (id, timestamp_ms, app_name, window_title, duration_ms) VALUES (1, 1700000000000, 'Mail', 'Inbox', 5000)",
		"INSERT INTO events (id, timestamp_ms, app_name, window_title, duration_ms) VALUES (2, 1700000005000, 'Safari', 'News', 5000)",
		// One mapped by a rule, one mapped by hand: neither is review work.
		"INSERT INTO events (id, timestamp_ms, app_name, window_title, duration_ms, project_id, activity_id) VALUES (3, 1700000010000, 'Ghostty', 'build', 5000, 10, 100)",
		"INSERT INTO events (id, timestamp_ms, app_name, window_title, duration_ms, manually_mapped) VALUES (4, 1700000015000, 'Slack', 'chat', 5000, true)",
	}
	for _, query := range inserts {
		if _, err := s.db.ExecContext(ctx, query); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}

	count, err := s.UnmappedEventCount(ctx)
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 2 {
		t.Fatalf("expected 2 unmapped events, got %d", count)
	}
}

func TestUnmappedEventCountAgreesWithTheUnmappedList(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	seedProjectActivity(t, s)
	ctx := context.Background()

	for _, query := range []string{
		"INSERT INTO events (id, timestamp_ms, app_name, window_title, duration_ms) VALUES (1, 1700000000000, 'Mail', 'Inbox', 5000)",
		"INSERT INTO events (id, timestamp_ms, app_name, window_title, duration_ms) VALUES (2, 1700000005000, 'Safari', 'News', 5000)",
		"INSERT INTO events (id, timestamp_ms, app_name, window_title, duration_ms, project_id, activity_id) VALUES (3, 1700000010000, 'Ghostty', 'build', 5000, 10, 100)",
	} {
		if _, err := s.db.ExecContext(ctx, query); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}

	listed, err := s.ListUnmappedEvents(ctx, nil, 0)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	count, err := s.UnmappedEventCount(ctx)
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != int64(len(listed)) {
		t.Fatalf("count %d disagrees with the list of %d", count, len(listed))
	}
}

func TestUnmappedEventCountIsZeroOnAnEmptyDatabase(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()

	count, err := s.UnmappedEventCount(context.Background())
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 0 {
		t.Fatalf("expected 0, got %d", count)
	}
}
