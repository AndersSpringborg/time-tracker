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
	unmapped         []domain.Event
	unmappedDates    []string
	grouped          []domain.GroupedEvent
	applied          []domain.EventMappingUpdate
	appliedManual    bool
	currentProjectID *int64
	projectByTitle   map[string]*int64
	activityByKey    map[string]*int64
	projects         []domain.Project
	activities       map[int64][]domain.Activity
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
func (f *fakeRulesRepo) ListAllProjects(context.Context) ([]domain.Project, error) {
	return f.projects, nil
}
func (f *fakeRulesRepo) ListActivitiesByProject(_ context.Context, projectID int64) ([]domain.Activity, error) {
	return f.activities[projectID], nil
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
	// one default skipped, all other defaults should remain.
	added := 0
	for _, row := range preview.Rows {
		if row.Change == domain.RuleDraftAdded {
			added++
		}
	}
	expected := len(domain.DefaultRules()) - 1
	if added != expected {
		t.Fatalf("expected %d added default rows, got %d", expected, added)
	}
}

func TestRulesUsecaseReAddDefaultRulesIsIdempotent(t *testing.T) {
	projectID := int64(10)
	activityID := int64(100)
	repo := &fakeRulesRepo{
		projectByTitle: map[string]*int64{
			"project a": &projectID,
		},
		activityByKey: map[string]*int64{
			fmt.Sprintf("%d::%s", projectID, "development"): &activityID,
		},
	}
	uc := NewRulesUsecase(repo)

	if _, err := uc.ReAddDefaultRulesToDraft(context.Background(), contracts.RulesDraftReAddDefaultsRequest{}); err != nil {
		t.Fatalf("first re-add defaults failed: %v", err)
	}
	if _, err := uc.ReAddDefaultRulesToDraft(context.Background(), contracts.RulesDraftReAddDefaultsRequest{}); err != nil {
		t.Fatalf("second re-add defaults failed: %v", err)
	}

	previewRes, err := uc.DraftPreview(context.Background(), contracts.RulesDraftPreviewRequest{})
	if err != nil {
		t.Fatalf("preview failed: %v", err)
	}
	preview := previewRes.Preview
	added := 0
	keys := map[string]struct{}{}
	for _, row := range preview.Rows {
		if row.Change != domain.RuleDraftAdded {
			continue
		}
		added++
		keys[row.Rule.RuleKey] = struct{}{}
	}

	expected := len(domain.DefaultRules())
	if added != expected {
		t.Fatalf("expected %d added default rows, got %d", expected, added)
	}
	if len(keys) != expected {
		t.Fatalf("expected %d unique default rule keys, got %d", expected, len(keys))
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

func TestRulesUsecaseAddRuleToDraftFromFormResolvesProjectAndActivityTitles(t *testing.T) {
	projectID := int64(10)
	activityID := int64(101)
	repo := &fakeRulesRepo{
		projectByTitle: map[string]*int64{"project a": &projectID},
		activityByKey: map[string]*int64{
			fmt.Sprintf("%d::%s", projectID, "meeting"): &activityID,
		},
	}
	uc := NewRulesUsecase(repo)

	_, err := uc.AddRuleToDraftFromForm(context.Background(), contracts.RulesDraftAddFromFormRequest{
		Rule: domain.RuleInput{
			ActionType:   domain.RuleActionAssignExplicit,
			Priority:     180,
			AppPattern:   "(?i)^Chrome$",
			TitlePattern: "(?i)^.*teams.*$",
		},
		TargetProjectName: "project a",
		TargetActivity:    "meeting",
	})
	if err != nil {
		t.Fatalf("add draft from form failed: %v", err)
	}

	previewRes, err := uc.DraftPreview(context.Background(), contracts.RulesDraftPreviewRequest{})
	if err != nil {
		t.Fatalf("preview failed: %v", err)
	}
	if len(previewRes.Preview.Rows) != 1 {
		t.Fatalf("expected one draft row, got %d", len(previewRes.Preview.Rows))
	}
	rule := previewRes.Preview.Rows[0].Rule
	if rule.ProjectID == nil || *rule.ProjectID != projectID {
		t.Fatalf("expected project id %d in staged rule, got %+v", projectID, rule.ProjectID)
	}
	if rule.ActivityID == nil || *rule.ActivityID != activityID {
		t.Fatalf("expected activity id %d in staged rule, got %+v", activityID, rule.ActivityID)
	}
}

func TestRulesUsecaseAddRuleToDraftFromFormRequiresTargetForExplicitAction(t *testing.T) {
	uc := NewRulesUsecase(&fakeRulesRepo{})
	_, err := uc.AddRuleToDraftFromForm(context.Background(), contracts.RulesDraftAddFromFormRequest{
		Rule: domain.RuleInput{
			ActionType: domain.RuleActionAssignExplicit,
		},
	})
	if err == nil {
		t.Fatalf("expected validation error")
	}
	if !strings.Contains(err.Error(), "select a project and activity target") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRulesUsecaseListAssignmentTargets(t *testing.T) {
	repo := &fakeRulesRepo{
		projects: []domain.Project{
			{ProjectID: 10, Title: "project a"},
			{ProjectID: 20, Title: "project b"},
		},
		activities: map[int64][]domain.Activity{
			10: {
				{ActivityID: 100, ProjectID: 10, Title: "development"},
				{ActivityID: 101, ProjectID: 10, Title: "meeting"},
			},
			20: {
				{ActivityID: 200, ProjectID: 20, Title: "planning"},
			},
		},
	}
	uc := NewRulesUsecase(repo)

	res, err := uc.ListAssignmentTargets(context.Background(), contracts.RulesAssignmentTargetsRequest{})
	if err != nil {
		t.Fatalf("list assignment targets failed: %v", err)
	}
	if len(res.Targets) != 3 {
		t.Fatalf("expected 3 targets, got %d", len(res.Targets))
	}
	if res.Targets[0].DisplayPath() != "project a > development" {
		t.Fatalf("unexpected first target: %+v", res.Targets[0])
	}
}

func TestRulesUsecaseApplyRulesPreviewReturnsGroupedMatches(t *testing.T) {
	projectID := int64(10)
	activityID := int64(100)
	repo := &fakeRulesRepo{
		rules: []domain.Rule{
			{
				ID:            1,
				Priority:      100,
				AppPattern:    "(?i)^Code$",
				TitlePattern:  "(?i)^.*$",
				ProjectID:     &projectID,
				ActivityID:    &activityID,
				ActionType:    domain.RuleActionAssignExplicit,
				DisplayTarget: "Project A > Development",
			},
		},
		grouped: []domain.GroupedEvent{
			{AppName: "Code", WindowTitle: "main.go", WifiSSID: "Office", TotalDurationMS: 5000, EventCount: 3},
			{AppName: "Slack", WindowTitle: "#general", WifiSSID: "Home", TotalDurationMS: 2000, EventCount: 2},
		},
		projects: []domain.Project{{ProjectID: 10, Title: "Project A"}},
		activities: map[int64][]domain.Activity{
			10: {{ActivityID: 100, ProjectID: 10, Title: "Development"}},
		},
	}
	uc := NewRulesUsecase(repo)

	date := "2026-02-10"
	res, err := uc.ApplyRulesPreview(context.Background(), contracts.RulesApplyPreviewRequest{
		Date:          &date,
		MinDurationMS: 0,
	})
	if err != nil {
		t.Fatalf("apply rules preview failed: %v", err)
	}

	if len(res.Matches) != 2 {
		t.Fatalf("expected 2 matches, got %d", len(res.Matches))
	}
	if res.MatchedCount != 1 {
		t.Fatalf("expected 1 matched group, got %d", res.MatchedCount)
	}
	if res.UnmappedCount != 1 {
		t.Fatalf("expected 1 unmatched group, got %d", res.UnmappedCount)
	}
	if res.TotalDurationMS != 7000 {
		t.Fatalf("expected total duration 7000, got %d", res.TotalDurationMS)
	}
	if res.MatchedDurationMS != 5000 {
		t.Fatalf("expected matched duration 5000, got %d", res.MatchedDurationMS)
	}

	// First match should be Code (matched)
	if res.Matches[0].AppName != "Code" {
		t.Fatalf("expected Code first, got %s", res.Matches[0].AppName)
	}
	if res.Matches[0].MatchedRule == nil {
		t.Fatalf("expected Code to have matched rule")
	}
	if res.Matches[0].WifiSSID != "Office" {
		t.Fatalf("expected matched group wifi to be preserved, got %q", res.Matches[0].WifiSSID)
	}

	// Second match should be Slack (unmatched)
	if res.Matches[1].AppName != "Slack" {
		t.Fatalf("expected Slack second, got %s", res.Matches[1].AppName)
	}
	if res.Matches[1].MatchedRule != nil {
		t.Fatalf("expected Slack to have no matched rule")
	}
	if res.Matches[1].WifiSSID != "Home" {
		t.Fatalf("expected unmatched group wifi to be preserved, got %q", res.Matches[1].WifiSSID)
	}

	// Assignment targets should be included
	if len(res.AssignmentTargets) != 1 {
		t.Fatalf("expected 1 assignment target, got %d", len(res.AssignmentTargets))
	}

	if res.Date != date {
		t.Fatalf("expected date %s, got %s", date, res.Date)
	}
}

func TestRulesUsecaseApplyRulesPreviewWithNoGroups(t *testing.T) {
	repo := &fakeRulesRepo{
		grouped: []domain.GroupedEvent{},
	}
	uc := NewRulesUsecase(repo)

	date := "2026-02-10"
	res, err := uc.ApplyRulesPreview(context.Background(), contracts.RulesApplyPreviewRequest{
		Date:          &date,
		MinDurationMS: 0,
	})
	if err != nil {
		t.Fatalf("apply rules preview failed: %v", err)
	}

	if len(res.Matches) != 0 {
		t.Fatalf("expected 0 matches, got %d", len(res.Matches))
	}
	if res.MatchedCount != 0 || res.UnmappedCount != 0 {
		t.Fatalf("expected zero counts")
	}
}
