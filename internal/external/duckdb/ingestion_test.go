package duckdb

import (
	"context"
	"errors"
	"path/filepath"
	"sync"
	"testing"

	"time-tracker/internal/application/usecases"
	"time-tracker/internal/domain"
)

func ingestBatch(sequences ...int64) domain.IngestBatch {
	b := domain.IngestBatch{ProducerID: "mac-123"}
	for _, seq := range sequences {
		b.Intervals = append(b.Intervals, domain.CapturedInterval{Sequence: seq, TimestampMS: seq * 5000, DurationMS: 5000, AppName: "Editor", WindowTitle: "Document", WifiSSID: "home"})
	}
	return b
}

func TestIngestionCommitsAndAcknowledgesReplays(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	u := usecases.NewIngestionUsecase(s)
	ctx := context.Background()
	for _, tt := range []struct {
		seq      []int64
		ack      int64
		inserted int
	}{{[]int64{1, 2}, 2, 2}, {[]int64{1, 2}, 2, 0}, {[]int64{2, 3}, 3, 1}, {[]int64{1}, 3, 0}} {
		got, err := u.Ingest(ctx, ingestBatch(tt.seq...))
		if err != nil {
			t.Fatal(err)
		}
		if got.AcknowledgedSequence != tt.ack || got.Inserted != tt.inserted {
			t.Fatalf("unexpected result %+v", got)
		}
	}
	var count, total int64
	if err := s.db.QueryRow("SELECT count(*),sum(duration_ms) FROM events").Scan(&count, &total); err != nil {
		t.Fatal(err)
	}
	if count != 3 || total != 15000 {
		t.Fatalf("count=%d total=%d", count, total)
	}
	if _, err := u.Ingest(ctx, ingestBatch(5)); !errors.Is(err, domain.ErrSequenceGap) {
		t.Fatalf("expected sequence gap, got %v", err)
	}
	b := ingestBatch(1)
	b.ProducerID = "other-mac"
	if _, err := u.Ingest(ctx, b); err != nil {
		t.Fatal(err)
	}
}

func TestIngestionRollsBackEventsAndCursorOnInsertFailure(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	ctx := context.Background()
	if _, err := s.db.Exec("CREATE UNIQUE INDEX test_unique_app ON events(app_name)"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.IngestBatch(ctx, ingestBatch(1, 2)); err == nil {
		t.Fatal("expected unique constraint failure")
	}
	var count int
	for _, table := range []string{"events", "ingestion_producers"} {
		if err := s.db.QueryRow("SELECT count(*) FROM " + table).Scan(&count); err != nil {
			t.Fatal(err)
		}
		if count != 0 {
			t.Fatalf("%s has %d rows after rollback", table, count)
		}
	}
	if got, err := s.IngestBatch(ctx, ingestBatch(1)); err != nil || got.AcknowledgedSequence != 1 {
		t.Fatalf("retry: %+v %v", got, err)
	}
}

func TestIngestionCursorSurvivesReopenAndEventDeletion(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tracker.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.IngestBatch(context.Background(), ingestBatch(1)); err != nil {
		t.Fatal(err)
	}
	if _, err = s.db.Exec("DELETE FROM events"); err != nil {
		t.Fatal(err)
	}
	if err = s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	got, err := s.IngestBatch(context.Background(), ingestBatch(1))
	if err != nil || got.Inserted != 0 || got.AcknowledgedSequence != 1 {
		t.Fatalf("replay after reopen: %+v %v", got, err)
	}
}

func TestIngestionSerializesConcurrentReplays(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := s.IngestBatch(context.Background(), ingestBatch(1)); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	var count int
	if err := s.db.QueryRow("SELECT count(*) FROM events").Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("expected one event, got %d", count)
	}
}

func TestIngestionRejectsInvalidBatchBeforeWriting(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	b := ingestBatch(1)
	b.Intervals[0].DurationMS = 0
	if _, err := usecases.NewIngestionUsecase(s).Ingest(context.Background(), b); !errors.Is(err, domain.ErrInvalidBatch) {
		t.Fatalf("expected invalid batch, got %v", err)
	}
	var count int
	if err := s.db.QueryRow("SELECT count(*) FROM events").Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("invalid batch wrote %d events", count)
	}
}
