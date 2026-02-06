package usecases

import (
	"context"
	"testing"

	"time-tracker/internal/domain"
)

type fakeRulesRepo struct {
	rules       []domain.Rule
	added       []domain.RuleInput
	deleted     []int64
	suggestions []domain.RuleSuggestion
	acceptCalls []domain.ApplySuggestionInput
}

func (f *fakeRulesRepo) ListRules(context.Context) ([]domain.Rule, error) { return f.rules, nil }
func (f *fakeRulesRepo) AddRule(_ context.Context, in domain.RuleInput) (int64, error) {
	f.added = append(f.added, in)
	return int64(len(f.added)), nil
}
func (f *fakeRulesRepo) DeleteRule(_ context.Context, id int64) error {
	f.deleted = append(f.deleted, id)
	return nil
}
func (f *fakeRulesRepo) AnalyzeSuggestions(context.Context, domain.SuggestionQuery) ([]domain.RuleSuggestion, error) {
	return f.suggestions, nil
}
func (f *fakeRulesRepo) AcceptSuggestion(_ context.Context, in domain.ApplySuggestionInput) (domain.ApplySuggestionResult, error) {
	f.acceptCalls = append(f.acceptCalls, in)
	return domain.ApplySuggestionResult{RuleCreated: true, MappedEvents: 3}, nil
}
func (f *fakeRulesRepo) ApplyRules(context.Context, domain.ApplyRulesInput) (domain.ApplyRulesResult, error) {
	return domain.ApplyRulesResult{MatchedEvents: 10}, nil
}

func TestRulesUsecaseAutoApplySuggestionsThreshold(t *testing.T) {
	repo := &fakeRulesRepo{
		suggestions: []domain.RuleSuggestion{
			{Confidence: 91, AppPattern: "Code", ActivityID: 1, KindID: 1},
			{Confidence: 80, AppPattern: "Slack", ActivityID: 2, KindID: 2},
			{Confidence: 95, AppPattern: "Arc", ActivityID: 3, KindID: 3},
		},
	}
	uc := NewRulesUsecase(repo)

	res, err := uc.AutoApplySuggestions(context.Background(), domain.AutoApplySuggestionsInput{MinConfidence: 90, ApplyNow: true})
	if err != nil {
		t.Fatalf("auto apply failed: %v", err)
	}

	if res.Accepted != 2 {
		t.Fatalf("expected 2 accepted suggestions, got %d", res.Accepted)
	}
	if len(repo.acceptCalls) != 2 {
		t.Fatalf("expected 2 accept calls, got %d", len(repo.acceptCalls))
	}
}
