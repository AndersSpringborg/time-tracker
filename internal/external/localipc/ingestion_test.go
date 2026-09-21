package localipc

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"time-tracker/internal/application/usecases"
	"time-tracker/internal/external/duckdb"
)

const validBatch = `{"producer_id":"test-client","intervals":[{"sequence":1,"timestamp_ms":1000,"duration_ms":5000,"app_name":"Editor","window_title":"file.go","wifi_ssid":"Office"}]}`

func TestIngestionAcknowledgesCommittedBatchAndReplay(t *testing.T) {
	store, err := duckdb.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	handler := NewIngestionHandler(usecases.NewIngestionUsecase(store))
	for _, wantInserted := range []int{1, 0} {
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/v1/events", strings.NewReader(validBatch)))
		if response.Code != http.StatusOK {
			t.Fatalf("response: %d %s", response.Code, response.Body)
		}
		var result struct {
			AcknowledgedSequence int64 `json:"acknowledged_sequence"`
			Inserted             int   `json:"inserted"`
		}
		if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		if result.AcknowledgedSequence != 1 || result.Inserted != wantInserted {
			t.Fatalf("unexpected result: %+v", result)
		}
	}
	events, err := store.ListReportEvents(context.Background(), "all", nil)
	if err != nil || len(events) != 1 {
		t.Fatalf("events=%v error=%v", events, err)
	}
	if events[0].DurationMS != 5000 || events[0].WindowTitle != "file.go" {
		t.Fatalf("unexpected event: %+v", events[0])
	}
}

func TestIngestionRejectsInvalidRequestsWithoutWriting(t *testing.T) {
	store, err := duckdb.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	handler := NewIngestionHandler(usecases.NewIngestionUsecase(store))
	for _, tc := range []struct {
		name, method, path, body string
		status                   int
	}{
		{"method", "GET", "/v1/events", validBatch, http.StatusMethodNotAllowed},
		{"version", "POST", "/v2/events", validBatch, http.StatusNotFound},
		{"malformed", "POST", "/v1/events", `{`, http.StatusBadRequest},
		{"empty", "POST", "/v1/events", `{}`, http.StatusBadRequest},
		{"null", "POST", "/v1/events", `null`, http.StatusBadRequest},
		{"unknown field", "POST", "/v1/events", strings.Replace(validBatch, `"producer_id"`, `"producer_typo"`, 1), http.StatusBadRequest},
		{"trailing data", "POST", "/v1/events", validBatch + ` {}`, http.StatusBadRequest},
		{"gap", "POST", "/v1/events", strings.Replace(validBatch, `"sequence":1`, `"sequence":2`, 1), http.StatusConflict},
		{"oversized", "POST", "/v1/events", validBatch + strings.Repeat(" ", 4*1024*1024), http.StatusRequestEntityTooLarge},
	} {
		t.Run(tc.name, func(t *testing.T) {
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body)))
			if response.Code != tc.status {
				t.Fatalf("response: %d %s; want %d", response.Code, response.Body, tc.status)
			}
			if bytes.Contains(response.Body.Bytes(), []byte("acknowledged_sequence")) {
				t.Fatal("failed request must not acknowledge")
			}
		})
	}
	events, err := store.ListReportEvents(context.Background(), "all", nil)
	if err != nil || len(events) != 0 {
		t.Fatalf("events=%v error=%v", events, err)
	}
}

func TestIngestionDoesNotAcknowledgeStorageFailure(t *testing.T) {
	store, err := duckdb.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	handler := NewIngestionHandler(usecases.NewIngestionUsecase(store))
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/v1/events", strings.NewReader(validBatch)))
	if response.Code != http.StatusServiceUnavailable || strings.Contains(response.Body.String(), "acknowledged_sequence") {
		t.Fatalf("response: %d %s", response.Code, response.Body)
	}
}

func TestIngestionReportsErrorsAsRetryableOrPermanent(t *testing.T) {
	store, err := duckdb.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	handler := NewIngestionHandler(usecases.NewIngestionUsecase(store))
	for _, tc := range []struct {
		name, method, path, body string
		retryable                bool
	}{
		{"malformed", "POST", "/v1/events", `{`, false},
		{"unsupported version", "POST", "/v2/events", validBatch, false},
		{"gap", "POST", "/v1/events", strings.Replace(validBatch, `"sequence":1`, `"sequence":2`, 1), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body)))
			assertErrorBody(t, response, tc.retryable)
		})
	}
	t.Run("storage failure", func(t *testing.T) {
		closed, err := duckdb.Open(":memory:")
		if err != nil {
			t.Fatal(err)
		}
		if err := closed.Close(); err != nil {
			t.Fatal(err)
		}
		response := httptest.NewRecorder()
		NewIngestionHandler(usecases.NewIngestionUsecase(closed)).ServeHTTP(response,
			httptest.NewRequest(http.MethodPost, "/v1/events", strings.NewReader(validBatch)))
		assertErrorBody(t, response, true)
	})
}

func assertErrorBody(t *testing.T, response *httptest.ResponseRecorder, wantRetryable bool) {
	t.Helper()
	if got := response.Header().Get("Content-Type"); got != "application/json" {
		t.Fatalf("content type: %q", got)
	}
	var body struct {
		Error     string `json:"error"`
		Retryable bool   `json:"retryable"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode %q: %v", response.Body, err)
	}
	if body.Error == "" {
		t.Fatal("error message must explain the rejection")
	}
	if body.Retryable != wantRetryable {
		t.Fatalf("retryable=%v; want %v (%s)", body.Retryable, wantRetryable, body.Error)
	}
}
