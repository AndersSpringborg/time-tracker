package usecases

import (
	"context"
	"testing"

	"time-tracker/internal/domain"
)

type fakeRulesRepo struct {
	rules            []domain.Rule
	added            []domain.RuleInput
	deleted          []int64
	appSuggestions   []domain.RuleSuggestion
	titleSuggestions []domain.RuleSuggestion
	unmapped         []domain.Event
	applied          []domain.EventMappingUpdate
	appliedManual    bool
	currentProjectID *int64
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
func (f *fakeRulesRepo) ListUnmappedEvents(context.Context, *string, int64) ([]domain.Event, error) {
	return f.unmapped, nil
}
func (f *fakeRulesRepo) ListAppSuggestions(context.Context, domain.SuggestionQuery) ([]domain.RuleSuggestion, error) {
	return f.appSuggestions, nil
}
func (f *fakeRulesRepo) ListTitleSuggestions(context.Context, domain.SuggestionQuery) ([]domain.RuleSuggestion, error) {
	return f.titleSuggestions, nil
}
func (f *fakeRulesRepo) ApplyEventMappings(_ context.Context, updates []domain.EventMappingUpdate, manuallyMapped bool) (int64, error) {
	f.applied = append(f.applied, updates...)
	f.appliedManual = manuallyMapped
	return int64(len(updates)), nil
}
func (f *fakeRulesRepo) CurrentProjectID(context.Context) (*int64, error) {
	return f.currentProjectID, nil
}

func TestRulesUsecaseAddRuleNormalizesDefaults(t *testing.T) {
	repo := &fakeRulesRepo{}
	uc := NewRulesUsecase(repo)
	_, err := uc.AddRule(context.Background(), domain.RuleInput{FollowPrevious: true})
	if err != nil {
		t.Fatalf("add rule failed: %v", err)
	}
	if len(repo.added) != 1 {
		t.Fatalf("expected one add call")
	}
	if repo.added[0].Priority != 100 || repo.added[0].AppPattern != "*" || repo.added[0].TitlePattern != "*" {
		t.Fatalf("expected normalized defaults")
	}
}

func TestRulesUsecaseAutoApplySuggestionsThreshold(t *testing.T) {
	repo := &fakeRulesRepo{
		appSuggestions: []domain.RuleSuggestion{
			{Confidence: 91, AppPattern: "Code", ProjectID: 10, ActivityID: 1, SuggestionType: domain.SuggestionTypeAppOnly, ImpactDurationMS: 3},
			{Confidence: 80, AppPattern: "Slack", ProjectID: 10, ActivityID: 2, SuggestionType: domain.SuggestionTypeAppOnly, ImpactDurationMS: 2},
			{Confidence: 95, AppPattern: "Arc", ProjectID: 10, ActivityID: 3, SuggestionType: domain.SuggestionTypeAppOnly, ImpactDurationMS: 1},
		},
	}
	uc := NewRulesUsecase(repo)

	res, err := uc.AutoApplySuggestions(context.Background(), domain.AutoApplySuggestionsInput{MinConfidence: 90, ApplyNow: false})
	if err != nil {
		t.Fatalf("auto apply failed: %v", err)
	}

	if res.Accepted != 2 {
		t.Fatalf("expected 2 accepted suggestions, got %d", res.Accepted)
	}
	if len(repo.added) != 2 {
		t.Fatalf("expected 2 add calls, got %d", len(repo.added))
	}
}

func TestRulesUsecaseApplyRulesUsesDomainEngine(t *testing.T) {
	cur := int64(10)
	p10 := int64(10)
	a100 := int64(100)
	repo := &fakeRulesRepo{
		currentProjectID: &cur,
		rules: []domain.Rule{
			{Priority: 100, AppPattern: "Code", TitlePattern: "*", ProjectID: &p10, ActivityID: &a100},
		},
		unmapped: []domain.Event{{ID: 1, TimestampMS: 1, AppName: "Code", WindowTitle: "main.go"}},
	}
	uc := NewRulesUsecase(repo)

	res, err := uc.ApplyRules(context.Background(), domain.ApplyRulesInput{DryRun: false})
	if err != nil {
		t.Fatalf("apply rules failed: %v", err)
	}
	if res.MatchedEvents != 1 {
		t.Fatalf("expected 1 matched event, got %d", res.MatchedEvents)
	}
	if len(repo.applied) != 1 {
		t.Fatalf("expected 1 persisted update, got %d", len(repo.applied))
	}
	if repo.applied[0].ProjectID != 10 || repo.applied[0].ActivityID != 100 {
		t.Fatalf("unexpected mapping target")
	}
}
