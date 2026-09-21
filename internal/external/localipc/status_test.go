package localipc

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"time-tracker/internal/application/usecases"
	"time-tracker/internal/external/duckdb"
)

func statusHandler(t *testing.T) (http.Handler, *duckdb.Store) {
	t.Helper()
	store, err := duckdb.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	return NewHandler(usecases.NewIngestionUsecase(store), usecases.NewStatusUsecase(store)), store
}

type statusReply struct {
	UnmatchedCount int64  `json:"unmatched_count"`
	Matched        bool   `json:"matched"`
	Project        string `json:"project"`
	Activity       string `json:"activity"`
}

func postStatus(t *testing.T, handler http.Handler, body string) (*httptest.ResponseRecorder, statusReply) {
	t.Helper()
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/v1/status", strings.NewReader(body)))
	var reply statusReply
	if response.Code == http.StatusOK {
		if err := json.Unmarshal(response.Body.Bytes(), &reply); err != nil {
			t.Fatalf("decode reply %q: %v", response.Body, err)
		}
	}
	return response, reply
}

func TestStatusReportsCountsForAnEmptyDatabase(t *testing.T) {
	handler, _ := statusHandler(t)

	response, reply := postStatus(t, handler, `{"app_name":"Mail","window_title":"Inbox"}`)

	if response.Code != http.StatusOK {
		t.Fatalf("response: %d %s", response.Code, response.Body)
	}
	if reply.UnmatchedCount != 0 || reply.Matched {
		t.Fatalf("unexpected reply: %+v", reply)
	}
}

func TestStatusCountsIngestedEventsNoRuleHasClaimed(t *testing.T) {
	handler, _ := statusHandler(t)

	ingest := httptest.NewRecorder()
	handler.ServeHTTP(ingest, httptest.NewRequest(http.MethodPost, "/v1/events", strings.NewReader(validBatch)))
	if ingest.Code != http.StatusOK {
		t.Fatalf("ingest: %d %s", ingest.Code, ingest.Body)
	}

	_, reply := postStatus(t, handler, `{}`)

	if reply.UnmatchedCount != 1 {
		t.Fatalf("expected the ingested event to need review, got %d", reply.UnmatchedCount)
	}
}

func TestStatusRejectsTheWrongMethodAndUnknownFields(t *testing.T) {
	handler, _ := statusHandler(t)

	get := httptest.NewRecorder()
	handler.ServeHTTP(get, httptest.NewRequest(http.MethodGet, "/v1/status", nil))
	if get.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405 for GET, got %d", get.Code)
	}

	response, _ := postStatus(t, handler, `{"app_name":"Mail","nonsense":1}`)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for an unknown field, got %d %s", response.Code, response.Body)
	}
}

func TestStatusRejectsAnOversizedRequest(t *testing.T) {
	handler, _ := statusHandler(t)

	huge := `{"app_name":"` + strings.Repeat("x", 128*1024) + `"}`
	response, _ := postStatus(t, handler, huge)

	if response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413, got %d %s", response.Code, response.Body)
	}
}

func TestIngestionStillServesItsOwnPathThroughTheCombinedHandler(t *testing.T) {
	handler, store := statusHandler(t)

	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/v1/events", strings.NewReader(validBatch)))
	if response.Code != http.StatusOK {
		t.Fatalf("response: %d %s", response.Code, response.Body)
	}
	events, err := store.ListReportEvents(t.Context(), "all", nil)
	if err != nil || len(events) != 1 {
		t.Fatalf("events=%v error=%v", events, err)
	}
}

func TestUnknownPathsAreStillRefused(t *testing.T) {
	handler, _ := statusHandler(t)

	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/v1/nonsense", strings.NewReader(`{}`)))
	if response.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d %s", response.Code, response.Body)
	}
}
