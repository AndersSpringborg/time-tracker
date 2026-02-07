package api

import (
	"bytes"
	"context"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	tidsregmodel "time-tracker/internal/application/integrations/tidsreg"
	"time-tracker/internal/application/usecases"
	"time-tracker/internal/domain"
)

type fakeRulesRepo struct{}

func (f *fakeRulesRepo) ListRules(context.Context) ([]domain.Rule, error)          { return nil, nil }
func (f *fakeRulesRepo) AddRule(context.Context, domain.RuleInput) (int64, error)  { return 1, nil }
func (f *fakeRulesRepo) UpdateRule(context.Context, int64, domain.RuleInput) error { return nil }
func (f *fakeRulesRepo) DeleteRule(context.Context, int64) error                   { return nil }
func (f *fakeRulesRepo) ApplyRulesetChanges(context.Context, domain.RulesetChanges) (domain.RulesetApplyResult, error) {
	return domain.RulesetApplyResult{}, nil
}
func (f *fakeRulesRepo) ListUnmappedEvents(context.Context, *string, int64) ([]domain.Event, error) {
	return nil, nil
}
func (f *fakeRulesRepo) ListUnmappedDates(context.Context, int64) ([]string, error) {
	return nil, nil
}
func (f *fakeRulesRepo) ListGroupedUnmappedEvents(context.Context, string, int64) ([]domain.GroupedEvent, error) {
	return nil, nil
}
func (f *fakeRulesRepo) ListAppSuggestions(context.Context, domain.SuggestionQuery) ([]domain.RuleSuggestion, error) {
	return nil, nil
}
func (f *fakeRulesRepo) ListTitleSuggestions(context.Context, domain.SuggestionQuery) ([]domain.RuleSuggestion, error) {
	title := "*standup*"
	return []domain.RuleSuggestion{{
		SuggestionType:   domain.SuggestionTypeAppAndTitle,
		AppPattern:       "Slack",
		TitlePattern:     &title,
		ProjectID:        10,
		ActivityID:       101,
		DisplayPath:      "web-app > meeting",
		Confidence:       88,
		ImpactCount:      3,
		ImpactDurationMS: 180000,
		EvidenceCount:    5,
	}}, nil
}
func (f *fakeRulesRepo) ApplyEventMappings(context.Context, []domain.EventMappingUpdate, bool) (int64, error) {
	return 0, nil
}
func (f *fakeRulesRepo) CurrentProjectID(context.Context) (*int64, error) { return nil, nil }
func (f *fakeRulesRepo) FindProjectIDByTitle(context.Context, string) (*int64, error) {
	return nil, nil
}
func (f *fakeRulesRepo) FindActivityIDByTitle(context.Context, int64, string) (*int64, error) {
	return nil, nil
}

func TestSuggestionsPartialRendersRows(t *testing.T) {
	app := &usecases.App{
		Rules: usecases.NewRulesUsecase(&fakeRulesRepo{}),
	}
	s, err := New(app)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	req := httptest.NewRequest(http.MethodGet, "/partials/suggestions", nil)
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Slack") {
		t.Fatalf("expected Slack in body, got %s", body)
	}
	if !strings.Contains(body, "Accept") {
		t.Fatalf("expected Accept button in body")
	}
}

func TestRulesPartialRendersDraftActions(t *testing.T) {
	app := &usecases.App{
		Rules: usecases.NewRulesUsecase(&fakeRulesRepo{}),
	}
	s, err := New(app)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	req := httptest.NewRequest(http.MethodGet, "/partials/rules", nil)
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Re add default rules") {
		t.Fatalf("expected re-add defaults button")
	}
	if !strings.Contains(body, "Draft Preview") {
		t.Fatalf("expected draft preview heading")
	}
}

func TestIntegrationsHubRendersTidsregCard(t *testing.T) {
	s, err := New(&usecases.App{})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/integrations", nil)
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Tidsreg") {
		t.Fatalf("expected tidsreg card in body")
	}
	if !strings.Contains(body, "href=\"/integrations/tidsreg\"") {
		t.Fatalf("expected tidsreg card link in body")
	}
}

func TestDocsPageRendersMarkdownAndActiveNav(t *testing.T) {
	s, err := New(&usecases.App{})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/docs", nil)
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Getting Started") {
		t.Fatalf("expected getting started heading in body")
	}
	if !strings.Contains(body, "href=\"/docs\" class=\"active\"") {
		t.Fatalf("expected docs nav link to be active")
	}
	if !strings.Contains(body, "language-mermaid") {
		t.Fatalf("expected mermaid code block in rendered markdown")
	}
}

func TestTidsregIntegrationPageRendersLoginForm(t *testing.T) {
	s, err := New(&usecases.App{})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/integrations/tidsreg", nil)
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "autocomplete=\"username\"") {
		t.Fatalf("expected username autocomplete in body")
	}
	if !strings.Contains(body, "Load Customers") {
		t.Fatalf("expected tidsreg login form in body")
	}
}

func TestTidsregCustomersTemplateDefaultsToUnchecked(t *testing.T) {
	s, err := New(&usecases.App{})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	rr := httptest.NewRecorder()
	s.render(rr, "partials/tidsreg_customers", pageData{
		TidsregCustomers: []tidsregmodel.Customer{{CustomerID: 1, Name: "Trifork"}},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if strings.Contains(body, "name=\"customer_ids\" value=\"1\" checked") {
		t.Fatalf("expected customer checkbox to start unchecked")
	}
}

func TestRequestLoggingMiddlewareLogsMethodPathAndStatus(t *testing.T) {
	s, err := New(&usecases.App{})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	var buf bytes.Buffer
	s.logger = log.New(&buf, "", 0)

	handler := s.requestLoggingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte("ok"))
	}))

	req := httptest.NewRequest(http.MethodPost, "/rules?draft=true", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d", rr.Code)
	}
	logLine := buf.String()
	if !strings.Contains(logLine, "method=POST") {
		t.Fatalf("expected method in log, got %s", logLine)
	}
	if !strings.Contains(logLine, "path=/rules?draft=true") {
		t.Fatalf("expected path in log, got %s", logLine)
	}
	if !strings.Contains(logLine, "status=201") {
		t.Fatalf("expected status in log, got %s", logLine)
	}
	if !strings.Contains(logLine, "duration_ms=") {
		t.Fatalf("expected duration in log, got %s", logLine)
	}
}

func TestRecoverMiddlewareReturns500AndLogsPanic(t *testing.T) {
	s, err := New(&usecases.App{})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	var buf bytes.Buffer
	s.logger = log.New(&buf, "", 0)

	handler := s.requestLoggingMiddleware(s.recoverMiddleware(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic("boom")
	})))

	req := httptest.NewRequest(http.MethodGet, "/panic", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d", rr.Code)
	}
	logLine := buf.String()
	if !strings.Contains(logLine, "panic method=GET path=/panic err=boom") {
		t.Fatalf("expected panic log, got %s", logLine)
	}
	if !strings.Contains(logLine, "status=500") {
		t.Fatalf("expected status log, got %s", logLine)
	}
}

func TestRequestLoggingMiddlewareIncludesErrorBody(t *testing.T) {
	s, err := New(&usecases.App{})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	var buf bytes.Buffer
	s.logger = log.New(&buf, "", 0)

	handler := s.requestLoggingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))

	req := httptest.NewRequest(http.MethodGet, "/failing", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d", rr.Code)
	}
	logLine := buf.String()
	if !strings.Contains(logLine, "status=500") {
		t.Fatalf("expected status in log, got %s", logLine)
	}
	if !strings.Contains(logLine, `error_body="boom"`) {
		t.Fatalf("expected error body in log, got %s", logLine)
	}
}

func TestRulesDraftAddFromSelectionLogsFailureDetails(t *testing.T) {
	app := &usecases.App{
		Rules: usecases.NewRulesUsecase(&fakeRulesRepo{}),
	}
	s, err := New(app)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	var buf bytes.Buffer
	s.logger = log.New(&buf, "", 0)

	form := url.Values{}
	form.Set("selected_idx", "0")
	form.Set("group_app_0", "Google Chrome")
	form.Set("group_title_0", "Daily standup")
	form.Set("action_type", "assign_explicit")
	form.Set("priority", "100")

	req := httptest.NewRequest(http.MethodPost, "/rules/draft/add-from-selection", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d body=%s", rr.Code, rr.Body.String())
	}
	logLine := buf.String()
	if !strings.Contains(logLine, "rules_add_from_selection parsed") {
		t.Fatalf("expected parsed log, got %s", logLine)
	}
	if !strings.Contains(logLine, "handler_error method=POST path=/rules/draft/add-from-selection") {
		t.Fatalf("expected handler error log, got %s", logLine)
	}
}
