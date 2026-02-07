package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

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
