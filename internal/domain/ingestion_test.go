package domain

import (
	"errors"
	"math"
	"strings"
	"testing"
)

func TestIngestBatchValidate(t *testing.T) {
	valid := func() IngestBatch {
		return IngestBatch{ProducerID: "mac-123", Intervals: []CapturedInterval{{Sequence: 1, TimestampMS: 100, DurationMS: 5000, AppName: "Editor"}}}
	}
	tests := []struct {
		name   string
		change func(*IngestBatch)
	}{
		{"empty producer", func(b *IngestBatch) { b.ProducerID = "" }},
		{"invalid producer", func(b *IngestBatch) { b.ProducerID = "mac / 1" }},
		{"long producer", func(b *IngestBatch) { b.ProducerID = strings.Repeat("x", 129) }},
		{"empty batch", func(b *IngestBatch) { b.Intervals = nil }},
		{"large batch", func(b *IngestBatch) { b.Intervals = make([]CapturedInterval, 257) }},
		{"zero sequence", func(b *IngestBatch) { b.Intervals[0].Sequence = 0 }},
		{"negative time", func(b *IngestBatch) { b.Intervals[0].TimestampMS = -1 }},
		{"time overflow", func(b *IngestBatch) { b.Intervals[0].TimestampMS = math.MaxInt64 }},
		{"zero duration", func(b *IngestBatch) { b.Intervals[0].DurationMS = 0 }},
		{"long duration", func(b *IngestBatch) { b.Intervals[0].DurationMS = 86400001 }},
		{"empty app", func(b *IngestBatch) { b.Intervals[0].AppName = " " }},
		{"long app", func(b *IngestBatch) { b.Intervals[0].AppName = strings.Repeat("x", 513) }},
		{"long title", func(b *IngestBatch) { b.Intervals[0].WindowTitle = strings.Repeat("x", 8193) }},
		{"invalid utf8", func(b *IngestBatch) { b.Intervals[0].WindowTitle = "\xff" }},
		{"long wifi", func(b *IngestBatch) { b.Intervals[0].WifiSSID = strings.Repeat("x", 257) }},
		{"sequence gap", func(b *IngestBatch) {
			next := b.Intervals[0]
			next.Sequence = 3
			b.Intervals = append(b.Intervals, next)
		}},
	}
	if err := valid().Validate(); err != nil {
		t.Fatal(err)
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			b := valid()
			tt.change(&b)
			if err := b.Validate(); !errors.Is(err, ErrInvalidBatch) {
				t.Fatalf("expected invalid batch, got %v", err)
			}
		})
	}
}
