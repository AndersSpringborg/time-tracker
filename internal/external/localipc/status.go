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
	statusPath      = "/v1/status"
	maxStatusBytes  = 64 * 1024
	statusUnhealthy = "status unavailable; retry"
)

type statusRequest struct {
	AppName     string `json:"app_name"`
	WindowTitle string `json:"window_title"`
}

// NewHandler serves the whole private IPC contract: ingestion and the
// read-only status the worker's menubar renders from a cached snapshot.
func NewHandler(ingestion *usecases.IngestionUsecase, status *usecases.StatusUsecase) http.Handler {
	events := NewIngestionHandler(ingestion)
	statusHandler := NewStatusHandler(status)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case statusPath:
			statusHandler.ServeHTTP(w, r)
		default:
			events.ServeHTTP(w, r)
		}
	})
}

// NewStatusHandler answers the menubar's status question. It only reads, so
// the worker may poll it without competing with ingestion for writes.
func NewStatusHandler(status *usecases.StatusUsecase) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			writeError(w, http.StatusMethodNotAllowed, false, "POST required")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxStatusBytes)
		defer r.Body.Close()
		decoder := json.NewDecoder(r.Body)
		decoder.DisallowUnknownFields()
		var request statusRequest
		if err := decoder.Decode(&request); err != nil {
			writeStatusDecodeError(w, err)
			return
		}
		var trailing any
		if err := decoder.Decode(&trailing); err != io.EOF {
			writeStatusDecodeError(w, err)
			return
		}

		result, err := status.Status(r.Context(), domain.WindowSnapshot{
			AppName: request.AppName, WindowTitle: request.WindowTitle,
		})
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, true, statusUnhealthy)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(struct {
			UnmatchedCount int64  `json:"unmatched_count"`
			Matched        bool   `json:"matched"`
			Project        string `json:"project"`
			Activity       string `json:"activity"`
		}{result.UnmatchedCount, result.Matched, result.Project, result.Activity})
	})
}

func writeStatusDecodeError(w http.ResponseWriter, err error) {
	var tooLarge *http.MaxBytesError
	if errors.As(err, &tooLarge) {
		writeError(w, http.StatusRequestEntityTooLarge, false, "status request exceeds 64 KiB")
		return
	}
	writeError(w, http.StatusBadRequest, false, "expected one status request object")
}
