package duckdb

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time-tracker/internal/domain"
)

// IngestBatch acknowledges only committed events. The producer cursor is retained
// independently of events so retention cannot make an old replay count twice.
func (s *Store) IngestBatch(ctx context.Context, batch domain.IngestBatch) (domain.IngestResult, error) {
	if err := batch.Validate(); err != nil {
		return domain.IngestResult{}, err
	}
	s.ingestionMu.Lock()
	defer s.ingestionMu.Unlock()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return domain.IngestResult{}, fmt.Errorf("begin ingestion: %w", err)
	}
	defer tx.Rollback()
	var ack int64
	err = tx.QueryRowContext(ctx, "SELECT acknowledged_sequence FROM ingestion_producers WHERE producer_id = ?", batch.ProducerID).Scan(&ack)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return domain.IngestResult{}, fmt.Errorf("read producer cursor: %w", err)
	}
	result := domain.IngestResult{AcknowledgedSequence: ack}
	for _, interval := range batch.Intervals {
		if interval.Sequence <= ack {
			continue
		}
		if interval.Sequence != result.AcknowledgedSequence+1 {
			return domain.IngestResult{}, fmt.Errorf("%w: expected %d, received %d", domain.ErrSequenceGap, result.AcknowledgedSequence+1, interval.Sequence)
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO events (timestamp_ms,duration_ms,app_name,window_title,wifi_ssid) VALUES (?,?,?,?,?)`, interval.TimestampMS, interval.DurationMS, interval.AppName, interval.WindowTitle, interval.WifiSSID); err != nil {
			return domain.IngestResult{}, fmt.Errorf("insert captured interval: %w", err)
		}
		result.AcknowledgedSequence = interval.Sequence
		result.Inserted++
	}
	if result.Inserted > 0 {
		if _, err := tx.ExecContext(ctx, `INSERT INTO ingestion_producers (producer_id,acknowledged_sequence) VALUES (?,?) ON CONFLICT (producer_id) DO UPDATE SET acknowledged_sequence = excluded.acknowledged_sequence`, batch.ProducerID, result.AcknowledgedSequence); err != nil {
			return domain.IngestResult{}, fmt.Errorf("update producer cursor: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return domain.IngestResult{}, fmt.Errorf("commit ingestion: %w", err)
	}
	return result, nil
}
