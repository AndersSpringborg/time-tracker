// Package localipc contains handlers for the private collector transport.
// These handlers must not be mounted on the browser-facing HTTP server.
package localipc

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"time-tracker/internal/application/usecases"
	"time-tracker/internal/domain"
)

const (
	maxBatchBytes = 4 * 1024 * 1024
	eventsPath    = "/v1/events"
)

type batchRequest struct {
	ProducerID string            `json:"producer_id"`
	Intervals  []intervalRequest `json:"intervals"`
}

type intervalRequest struct {
	Sequence    int64  `json:"sequence"`
	TimestampMS int64  `json:"timestamp_ms"`
	DurationMS  int64  `json:"duration_ms"`
	AppName     string `json:"app_name"`
	WindowTitle string `json:"window_title"`
	WifiSSID    string `json:"wifi_ssid"`
}

// NewIngestionHandler serves the v1 ingestion contract. The service entrypoint
// will bind it to a user-restricted Unix socket during the collector cutover.
func NewIngestionHandler(ingestion *usecases.IngestionUsecase) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != eventsPath {
			writeError(w, http.StatusNotFound, false, "unsupported request path; this service speaks "+eventsPath)
			return
		}
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			writeError(w, http.StatusMethodNotAllowed, false, "POST required")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxBatchBytes)
		defer r.Body.Close()
		decoder := json.NewDecoder(r.Body)
		decoder.DisallowUnknownFields()
		var request batchRequest
		if err := decoder.Decode(&request); err != nil {
			writeDecodeError(w, err)
			return
		}
		// Consume through EOF before writing, rejecting trailing JSON or an
		// oversized body even when its first object is a valid batch.
		var trailing any
		if err := decoder.Decode(&trailing); err != io.EOF {
			writeDecodeError(w, err)
			return
		}
		batch := domain.IngestBatch{ProducerID: request.ProducerID}
		for _, interval := range request.Intervals {
			batch.Intervals = append(batch.Intervals, domain.CapturedInterval{
				Sequence: interval.Sequence, TimestampMS: interval.TimestampMS,
				DurationMS: interval.DurationMS, AppName: interval.AppName,
				WindowTitle: interval.WindowTitle, WifiSSID: interval.WifiSSID,
			})
		}
		result, err := ingestion.Ingest(r.Context(), batch)
		if err != nil {
			switch {
			case errors.Is(err, domain.ErrInvalidBatch):
				writeError(w, http.StatusBadRequest, false, err.Error())
			case errors.Is(err, domain.ErrSequenceGap):
				writeError(w, http.StatusConflict, false, err.Error())
			default:
				writeError(w, http.StatusServiceUnavailable, true, "ingestion unavailable; retry batch")
			}
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(struct {
			AcknowledgedSequence int64 `json:"acknowledged_sequence"`
			Inserted             int   `json:"inserted"`
		}{result.AcknowledgedSequence, result.Inserted})
	})
}

func writeDecodeError(w http.ResponseWriter, err error) {
	var tooLarge *http.MaxBytesError
	if errors.As(err, &tooLarge) {
		writeError(w, http.StatusRequestEntityTooLarge, false, "batch exceeds 4 MiB; send smaller batches")
		return
	}
	writeError(w, http.StatusBadRequest, false, "expected one valid batch object")
}

// writeError states whether the sender may retry, so a client outbox can keep
// unsent activity for transient failures and drop nothing silently otherwise.
func writeError(w http.ResponseWriter, status int, retryable bool, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(struct {
		Error     string `json:"error"`
		Retryable bool   `json:"retryable"`
	}{message, retryable})
}
