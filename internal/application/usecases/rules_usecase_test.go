package usecases

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"time-tracker/internal/application/contracts"
	"time-tracker/internal/domain"
)

type fakeRulesRepo struct {
	rules            []domain.Rule
	added            []domain.RuleInput
	updated          []domain.RuleUpdate
	deleted          []int64
	appliedChanges   domain.RulesetChanges
	appSuggestions   []domain.RuleSuggestion
	titleSuggestions []domain.RuleSuggestion
	unmapped         []domain.Event
	unmappedDates    []string
	grouped          []domain.GroupedEvent
	applied          []domain.EventMappingUpdate
	appliedManual    bool
	currentProjectID *int64
	projectByTitle   map[string]*int64
	activityByKey    map[string]*int64
}

func (f *fakeRulesRepo) ListRules(context.Context) ([]domain.Rule, error) { return f.rules, nil }
func (f *fakeRulesRepo) AddRule(_ context.Context, in domain.RuleInput) (int64, error) {
	f.added = append(f.added, in)
	return int64(len(f.added)), nil
}
func (f *fakeRulesRepo) UpdateRule(_ context.Context, id int64, in domain.RuleInput) error {
	f.updated = append(f.updated, domain.RuleUpdate{ID: id, Rule: in})
	return nil
}
func (f *fakeRulesRepo) DeleteRule(_ context.Context, id int64) error {
	f.deleted = append(f.deleted, id)
	return nil
}
func (f *fakeRulesRepo) ApplyRulesetChanges(_ context.Context, in domain.RulesetChanges) (domain.RulesetApplyResult, error) {
	f.appliedChanges = in
	return domain.RulesetApplyResult{
		Added:   len(in.Adds),
		Updated: len(in.Updates),
		Deleted: len(in.Deletes),
	}, nil
}
func (f *fakeRulesRepo) ListUnmappedEvents(context.Context, *string, int64) ([]domain.Event, error) {
	return f.unmapped, nil
}
func (f *fakeRulesRepo) ListUnmappedDates(context.Context, int64) ([]string, error) {
	return f.unmappedDates, nil
}
func (f *fakeRulesRepo) ListGroupedUnmappedEvents(context.Context, string, int64) ([]domain.GroupedEvent, error) {
	return f.grouped, nil
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
func (f *fakeRulesRepo) FindProjectIDByTitle(_ context.Context, title string) (*int64, error) {
	return f.projectByTitle[strings.ToLower(strings.TrimSpace(title))], nil
}
func (f *fakeRulesRepo) FindActivityIDByTitle(_ context.Context, projectID int64, title string) (*int64, error) {
	return f.activityByKey[fmt.Sprintf("%d::%s", projectID, strings.ToLower(strings.TrimSpace(title)))], nil
}

func TestRulesUsecaseAddRuleNormalizesDefaults(t *testing.T) {
	repo := &fakeRulesRepo{}
	uc := NewRulesUsecase(repo)
	_, err := uc.AddRule(context.Background(), contracts.RulesAddRequest{Rule: domain.RuleInput{FollowPrevious: true}})
	if err != nil {
		t.Fatalf("add rule failed: %v", err)
	}
	if len(repo.added) != 1 {
		t.Fatalf("expected one add call")
	}
	if repo.added[0].Priority != 100 || repo.added[0].AppPattern != "(?i)^.*$" || repo.added[0].TitlePattern != "(?i)^.*$" {
		t.Fatalf("expected normalized defaults")
	}
	if repo.added[0].ActionType != domain.RuleActionFollowCurrentContext {
		t.Fatalf("expected follow current action")
	}
}

func TestRulesUsecaseDraftPreviewSaveAndDiscard(t *testing.T) {
	projectID := int64(10)
	activityID := int64(100)
	repo := &fakeRulesRepo{
		rules: []domain.Rule{
			{
				ID:           1,
				Priority:     100,
				AppPattern:   "(?i)^Code$",
				TitlePattern: "(?i)^.*$",
				ProjectID:    &projectID,
				ActivityID:   &activityID,
				ActionType:   domain.RuleActionAssignExplicit,
			},
		},
	}
	uc := NewRulesUsecase(repo)

	if _, err := uc.AddRuleToDraft(context.Background(), contracts.RulesDraftAddRequest{Rule: domain.RuleInput{
		Priority:     200,
		AppPattern:   "(?i)^Arc$",
		TitlePattern: "(?i)^.*zoom.*$",
		ProjectID:    &projectID,
		ActivityID:   &activityID,
	}}); err != nil {
		t.Fatalf("add draft rule failed: %v", err)
	}
	if _, err := uc.DeleteRuleFromDraft(context.Background(), contracts.RulesDraftDeleteRequest{RuleID: 1}); err != nil {
		t.Fatalf("delete draft rule failed: %v", err)
	}

	previewRes, err := uc.DraftPreview(context.Background(), contracts.RulesDraftPreviewRequest{})
	if err != nil {
		t.Fatalf("draft preview failed: %v", err)
	}
	preview := previewRes.Preview
	if !preview.HasChanges {
		t.Fatalf("expected pending changes")
	}
	if len(preview.Rows) != 2 {
		t.Fatalf("expected 2 preview rows, got %d", len(preview.Rows))
	}

	res, err := uc.SaveDraft(context.Background(), contracts.RulesDraftSaveRequest{})
	if err != nil {
		t.Fatalf("save draft failed: %v", err)
	}
	if res.Result.Added != 1 || res.Result.Deleted != 1 {
		t.Fatalf("unexpected save result %+v", res)
	}
	if len(repo.appliedChanges.Adds) != 1 || len(repo.appliedChanges.Deletes) != 1 {
		t.Fatalf("expected 1 add and 1 delete change")
	}

	if _, err := uc.AddRuleToDraft(context.Background(), contracts.RulesDraftAddRequest{Rule: domain.RuleInput{
		Priority:     100,
		AppPattern:   "(?i)^Firefox$",
		TitlePattern: "(?i)^.*$",
		ProjectID:    &projectID,
		ActivityID:   &activityID,
	}}); err != nil {
		t.Fatalf("second add draft rule failed: %v", err)
	}
	if _, err := uc.DiscardDraft(context.Background(), contracts.RulesDraftDiscardRequest{}); err != nil {
		t.Fatalf("discard draft failed: %v", err)
	}

	previewRes, err = uc.DraftPreview(context.Background(), contracts.RulesDraftPreviewRequest{})
	if err != nil {
		t.Fatalf("preview after discard failed: %v", err)
	}
	preview = previewRes.Preview
	if preview.HasChanges {
		t.Fatalf("expected no changes after discard")
	}
}

func TestRulesUsecaseReAddDefaultRulesSkipsMissingProject(t *testing.T) {
	repo := &fakeRulesRepo{
		projectByTitle: map[string]*int64{},
		activityByKey:  map[string]*int64{},
	}
	uc := NewRulesUsecase(repo)

	readdRes, err := uc.ReAddDefaultRulesToDraft(context.Background(), contracts.RulesDraftReAddDefaultsRequest{})
	if err != nil {
		t.Fatalf("re-add defaults failed: %v", err)
	}
	warnings := readdRes.Warnings
	if len(warnings) == 0 {
		t.Fatalf("expected warning for missing project a/development")
	}

	previewRes, err := uc.DraftPreview(context.Background(), contracts.RulesDraftPreviewRequest{})
	if err != nil {
		t.Fatalf("preview failed: %v", err)
	}
	preview := previewRes.Preview
	// one default skipped, two should remain.
	added := 0
	for _, row := range preview.Rows {
		if row.Change == domain.RuleDraftAdded {
			added++
		}
	}
	if added != 2 {
		t.Fatalf("expected 2 added default rows, got %d", added)
	}
}

func TestRulesUsecaseAddRegexRuleFromGroups(t *testing.T) {
	projectID := int64(10)
	activityID := int64(100)
	repo := &fakeRulesRepo{}
	uc := NewRulesUsecase(repo)
	_, err := uc.AddRegexRuleFromGroupsToDraft(context.Background(), contracts.RulesDraftAddFromGroupsRequest{
		Groups: []domain.GroupedEvent{
			{AppName: "Firefox", WindowTitle: "Project Name A"},
			{AppName: "Arc", WindowTitle: "Teams"},
		},
		Rule: domain.RuleInput{
			Priority:   200,
			ProjectID:  &projectID,
			ActivityID: &activityID,
		},
	})
	if err != nil {
		t.Fatalf("add regex draft rule failed: %v", err)
	}

	previewRes, err := uc.DraftPreview(context.Background(), contracts.RulesDraftPreviewRequest{})
	if err != nil {
		t.Fatalf("preview failed: %v", err)
	}
	preview := previewRes.Preview
	if len(preview.Rows) != 1 {
		t.Fatalf("expected one preview row, got %d", len(preview.Rows))
	}
	if !strings.Contains(preview.Rows[0].Rule.AppPattern, "Firefox") || !strings.Contains(preview.Rows[0].Rule.AppPattern, "Arc") {
		t.Fatalf("expected app regex to include selected apps")
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

	res, err := uc.AutoApplySuggestions(context.Background(), contracts.RulesAutoApplySuggestionsRequest{
		Input: domain.AutoApplySuggestionsInput{MinConfidence: 90, ApplyNow: false},
	})
	if err != nil {
		t.Fatalf("auto apply failed: %v", err)
	}

	if res.Result.Accepted != 2 {
		t.Fatalf("expected 2 accepted suggestions, got %d", res.Result.Accepted)
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
			{Priority: 100, AppPattern: "(?i)^Code$", TitlePattern: "(?i)^.*$", ProjectID: &p10, ActivityID: &a100, ActionType: domain.RuleActionAssignExplicit},
		},
		unmapped: []domain.Event{{ID: 1, TimestampMS: 1, AppName: "Code", WindowTitle: "main.go"}},
	}
	uc := NewRulesUsecase(repo)

	res, err := uc.ApplyRules(context.Background(), contracts.RulesApplyRequest{Input: domain.ApplyRulesInput{DryRun: false}})
	if err != nil {
		t.Fatalf("apply rules failed: %v", err)
	}
	if res.Result.MatchedEvents != 1 {
		t.Fatalf("expected 1 matched event, got %d", res.Result.MatchedEvents)
	}
	if len(repo.applied) != 1 {
		t.Fatalf("expected 1 persisted update, got %d", len(repo.applied))
	}
	if repo.applied[0].ProjectID != 10 || repo.applied[0].ActivityID != 100 {
		t.Fatalf("unexpected mapping target")
	}
}
