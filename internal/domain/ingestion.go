package domain

import (
	"errors"
	"fmt"
	"math"
	"strings"
	"unicode/utf8"
)

var ErrInvalidBatch = errors.New("invalid ingestion batch")
var ErrSequenceGap = errors.New("ingestion sequence gap")

const MaxIngestIntervals = 256

type CapturedInterval struct {
	Sequence    int64
	TimestampMS int64
	DurationMS  int64
	AppName     string
	WindowTitle string
	WifiSSID    string
}

type IngestBatch struct {
	ProducerID string
	Intervals  []CapturedInterval
}

type IngestResult struct {
	AcknowledgedSequence int64
	Inserted             int
}

func (b IngestBatch) Validate() error {
	if len(b.ProducerID) == 0 || len(b.ProducerID) > 128 {
		return fmt.Errorf("%w: producer ID must contain 1–128 bytes", ErrInvalidBatch)
	}
	for _, c := range b.ProducerID {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return fmt.Errorf("%w: producer ID must be an ASCII identifier", ErrInvalidBatch)
		}
	}
	if len(b.Intervals) == 0 || len(b.Intervals) > MaxIngestIntervals {
		return fmt.Errorf("%w: batch must contain 1–%d intervals", ErrInvalidBatch, MaxIngestIntervals)
	}
	for i, v := range b.Intervals {
		if v.Sequence <= 0 || (i > 0 && (b.Intervals[i-1].Sequence == math.MaxInt64 || v.Sequence != b.Intervals[i-1].Sequence+1)) {
			return fmt.Errorf("%w: sequences must be positive and contiguous", ErrInvalidBatch)
		}
		if v.DurationMS <= 0 || v.DurationMS > 86400000 || v.TimestampMS < 0 || v.TimestampMS > math.MaxInt64-v.DurationMS {
			return fmt.Errorf("%w: invalid interval time", ErrInvalidBatch)
		}
		if strings.TrimSpace(v.AppName) == "" || len(v.AppName) > 512 || len(v.WindowTitle) > 8192 || len(v.WifiSSID) > 256 || !utf8.ValidString(v.AppName) || !utf8.ValidString(v.WindowTitle) || !utf8.ValidString(v.WifiSSID) {
			return fmt.Errorf("%w: invalid interval text", ErrInvalidBatch)
		}
	}
	return nil
}
