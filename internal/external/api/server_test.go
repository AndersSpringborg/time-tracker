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
func (f *fakeRulesRepo) ListAllProjects(context.Context) ([]domain.Project, error) {
	return []domain.Project{
		{ProjectID: 10, Title: "project a"},
	}, nil
}
func (f *fakeRulesRepo) ListActivitiesByProject(context.Context, int64) ([]domain.Activity, error) {
	return []domain.Activity{
		{ActivityID: 100, ProjectID: 10, Title: "development"},
		{ActivityID: 101, ProjectID: 10, Title: "meeting"},
	}, nil
}

type fakeReportsRepoForAPI struct{}

func (f *fakeReportsRepoForAPI) ListReportEvents(context.Context, string, *string) ([]domain.Event, error) {
	return []domain.Event{
		{
			ID:           1,
			TimestampMS:  1,
			DurationMS:   60_000,
			AppName:      "Code",
			ProjectTitle: "project a",
		},
	}, nil
}

type fakeProjectsRepoForAPI struct{}

func (fakeProjectsRepoForAPI) ListActiveProjects(context.Context) ([]domain.Project, error) {
	return nil, nil
}
func (fakeProjectsRepoForAPI) ListAllProjects(context.Context) ([]domain.Project, error) {
	return nil, nil
}
func (fakeProjectsRepoForAPI) ActivateProject(context.Context, int64) error { return nil }
func (fakeProjectsRepoForAPI) EndProject(context.Context, int64) error      { return nil }
func (fakeProjectsRepoForAPI) EndAllProjects(context.Context) error         { return nil }
func (fakeProjectsRepoForAPI) CurrentProject(context.Context) (string, *int64, error) {
	return "", nil, nil
}

type fakeSettingsRepoForAPI struct{}

func (fakeSettingsRepoForAPI) Load(context.Context) (domain.Settings, string, error) {
	return domain.Settings{}, "", nil
}
func (fakeSettingsRepoForAPI) Save(context.Context, domain.Settings) (string, error) {
	return "", nil
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
	if !strings.Contains(body, "Project + Activity") {
		t.Fatalf("expected project + activity selector")
	}
	if strings.Contains(body, "Project ID") {
		t.Fatalf("expected rules editor not to render project id field")
	}
}

func TestReportsPageRendersDayNavigationControls(t *testing.T) {
	app := &usecases.App{
		Reports: usecases.NewReportsUsecase(&fakeReportsRepoForAPI{}, fakeProjectsRepoForAPI{}, fakeSettingsRepoForAPI{}),
	}
	s, err := New(app)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/reports", nil)
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Previous day") {
		t.Fatalf("expected previous day control")
	}
	if !strings.Contains(body, `type="date"`) {
		t.Fatalf("expected date input")
	}
	if !strings.Contains(body, "Refresh range") {
		t.Fatalf("expected range refresh button")
	}
}

func TestReportsPartialShowsDateContext(t *testing.T) {
	app := &usecases.App{
		Reports: usecases.NewReportsUsecase(&fakeReportsRepoForAPI{}, fakeProjectsRepoForAPI{}, fakeSettingsRepoForAPI{}),
	}
	s, err := New(app)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/partials/reports?range=all&date=2026-02-07", nil)
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Showing date: 2026-02-07") {
		t.Fatalf("expected selected date context, got %s", body)
	}
}

func TestReportsPartialShowsRangeContextWithoutDate(t *testing.T) {
	app := &usecases.App{
		Reports: usecases.NewReportsUsecase(&fakeReportsRepoForAPI{}, fakeProjectsRepoForAPI{}, fakeSettingsRepoForAPI{}),
	}
	s, err := New(app)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/partials/reports?range=week", nil)
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Showing range: week") {
		t.Fatalf("expected range context, got %s", body)
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
	if !strings.Contains(body, "Load Step 1: Customers") {
		t.Fatalf("expected tidsreg login form in body")
	}
	if !strings.Contains(body, "id=\"tidsreg-loader\"") {
		t.Fatalf("expected tidsreg loader in body")
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
	if !strings.Contains(body, "hx-post=\"/integrations/tidsreg/projects\"") {
		t.Fatalf("expected customers step to post to projects route")
	}
	if !strings.Contains(body, "Check/Uncheck All") {
		t.Fatalf("expected check/uncheck button in customers step")
	}
	if !strings.Contains(body, "hx-indicator=\"#tidsreg-loader\"") {
		t.Fatalf("expected customers step loader indicator wiring")
	}
}

func TestTidsregProjectsTemplateRendersProjectSelection(t *testing.T) {
	s, err := New(&usecases.App{})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	rr := httptest.NewRecorder()
	s.render(rr, "partials/tidsreg_projects", pageData{
		TidsregProjects: []tidsregmodel.Project{{
			ProjectID:    42,
			CustomerID:   7,
			Name:         "Portal",
			CustomerName: "Trifork",
		}},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "name=\"project_ids\" value=\"42\"") {
		t.Fatalf("expected project checkbox in projects step")
	}
	if !strings.Contains(body, "Check/Uncheck All") {
		t.Fatalf("expected check/uncheck button in projects step")
	}
	if !strings.Contains(body, "hx-indicator=\"#tidsreg-loader\"") {
		t.Fatalf("expected projects step loader indicator wiring")
	}
}

func TestTidsregPreviewTemplateRendersActivityNames(t *testing.T) {
	s, err := New(&usecases.App{})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	rr := httptest.NewRecorder()
	s.render(rr, "partials/tidsreg_preview", pageData{
		TidsregPreview: tidsregmodel.ImportPreview{
			Candidates: []tidsregmodel.ImportCandidate{{
				Key:          "1:10:100",
				CustomerName: "Trifork",
				ProjectName:  "Portal",
				PhaseName:    "Build",
				TargetTitle:  "Trifork > Portal > Build",
				Activities: []tidsregmodel.Activity{
					{ActivityID: 1, Name: "Development"},
					{ActivityID: 2, Name: "Meeting"},
					{ActivityID: 3, Name: "Design"},
				},
			}},
		},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Development, Meeting, Design") {
		t.Fatalf("expected activity names in preview body, got %s", body)
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
	form.Set("target_path", encodeRuleTargetPath("project a", "meeting"))

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
	if !strings.Contains(logLine, "target_project=\"project a\"") {
		t.Fatalf("expected target project in log, got %s", logLine)
	}
	if !strings.Contains(logLine, "handler_error method=POST path=/rules/draft/add-from-selection") {
		t.Fatalf("expected handler error log, got %s", logLine)
	}
}

func TestRuleTargetPathEncodingRoundTrip(t *testing.T) {
	encoded := encodeRuleTargetPath("project a", "development")
	project, activity, err := decodeRuleTargetPath(encoded)
	if err != nil {
		t.Fatalf("decode rule target failed: %v", err)
	}
	if project != "project a" || activity != "development" {
		t.Fatalf("unexpected decoded values project=%q activity=%q", project, activity)
	}
}
