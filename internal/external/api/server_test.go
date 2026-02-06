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

func (f *fakeRulesRepo) ListRules(context.Context) ([]domain.Rule, error)         { return nil, nil }
func (f *fakeRulesRepo) AddRule(context.Context, domain.RuleInput) (int64, error) { return 1, nil }
func (f *fakeRulesRepo) DeleteRule(context.Context, int64) error                  { return nil }
func (f *fakeRulesRepo) AnalyzeSuggestions(context.Context, domain.SuggestionQuery) ([]domain.RuleSuggestion, error) {
	title := "*standup*"
	return []domain.RuleSuggestion{{
		SuggestionType:   domain.SuggestionTypeAppAndTitle,
		AppPattern:       "Slack",
		TitlePattern:     &title,
		ActivityID:       1000,
		KindID:           10000,
		DisplayPath:      "Acme > Platform > Build > Coding > Feature",
		Confidence:       88,
		ImpactCount:      3,
		ImpactDurationMS: 180000,
		EvidenceCount:    5,
	}}, nil
}
func (f *fakeRulesRepo) AcceptSuggestion(context.Context, domain.ApplySuggestionInput) (domain.ApplySuggestionResult, error) {
	return domain.ApplySuggestionResult{RuleCreated: true, MappedEvents: 3}, nil
}
func (f *fakeRulesRepo) ApplyRules(context.Context, domain.ApplyRulesInput) (domain.ApplyRulesResult, error) {
	return domain.ApplyRulesResult{UnmappedEvents: 3, MatchedEvents: 3}, nil
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
