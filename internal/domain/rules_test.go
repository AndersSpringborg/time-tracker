package domain

import (
	"fmt"
	"testing"
)

type stubRuleResolver struct {
	projectByTitle map[string]*int64
	activityByKey  map[string]*int64
}

func (s stubRuleResolver) FindProjectIDByTitle(title string) (*int64, error) {
	return s.projectByTitle[title], nil
}

func (s stubRuleResolver) FindActivityIDByTitle(projectID int64, activityTitle string) (*int64, error) {
	return s.activityByKey[activityKey(projectID, activityTitle)], nil
}

func activityKey(projectID int64, activityTitle string) string {
	return fmt.Sprintf("%d::%s", projectID, activityTitle)
}

func TestNormalizeRuleInputDefaults(t *testing.T) {
	in := NormalizeRuleInput(RuleInput{})
	if in.Priority != 100 {
		t.Fatalf("expected default priority 100, got %d", in.Priority)
	}
	if in.AppPattern != matchAnyRegex || in.TitlePattern != matchAnyRegex {
		t.Fatalf("expected regex wildcard defaults, got app=%q title=%q", in.AppPattern, in.TitlePattern)
	}
	if in.ActionType != RuleActionAssignExplicit {
		t.Fatalf("expected default action assign explicit, got %s", in.ActionType)
	}
}

func TestNormalizeRuleInputConvertsGlobToRegex(t *testing.T) {
	in := NormalizeRuleInput(RuleInput{
		AppPattern:   "*Chrome*",
		TitlePattern: "*project*",
	})
	if in.AppPattern != "(?i)^.*Chrome.*$" {
		t.Fatalf("unexpected app regex: %s", in.AppPattern)
	}
	if in.TitlePattern != "(?i)^.*project.*$" {
		t.Fatalf("unexpected title regex: %s", in.TitlePattern)
	}
}

func TestRuleMatchesRegexPattern(t *testing.T) {
	r := Rule{
		AppPattern:   "(?i)^(Firefox|Arc)$",
		TitlePattern: "(?i)^.*teams.*$",
	}
	if !r.Matches(Event{AppName: "Firefox", WindowTitle: "Daily Teams Sync"}) {
		t.Fatalf("expected regex rule to match")
	}
	if r.Matches(Event{AppName: "Safari", WindowTitle: "Daily Teams Sync"}) {
		t.Fatalf("did not expect Safari to match")
	}
}

func TestRuleResolveTargetFollowCurrentContext(t *testing.T) {
	projectID := int64(10)
	activityID := int64(100)
	rule := Rule{ActionType: RuleActionFollowCurrentContext}
	target, err := rule.ResolveTarget(RuleContext{
		PreviousProjectID:  &projectID,
		PreviousActivityID: &activityID,
	}, nil)
	if err != nil {
		t.Fatalf("resolve target returned error: %v", err)
	}
	if target == nil {
		t.Fatalf("expected resolved target")
	}
	if target.ProjectID != projectID || target.ActivityID != activityID {
		t.Fatalf("unexpected target %+v", target)
	}
}

func TestRuleResolveTargetAssignActivityInCurrentProject(t *testing.T) {
	projectID := int64(20)
	meetingID := int64(201)
	resolver := stubRuleResolver{
		activityByKey: map[string]*int64{
			activityKey(projectID, "meeting"): &meetingID,
		},
	}
	rule := Rule{
		ActionType:         RuleActionAssignActivityCurrent,
		ActionActivityName: "meeting",
	}
	target, err := rule.ResolveTarget(RuleContext{CurrentProjectID: &projectID}, resolver)
	if err != nil {
		t.Fatalf("resolve target returned error: %v", err)
	}
	if target == nil {
		t.Fatalf("expected resolved target")
	}
	if target.ProjectID != projectID || target.ActivityID != meetingID {
		t.Fatalf("unexpected target %+v", target)
	}
}

func TestRuleResolveTargetAssignProjectAndActivityByTitle(t *testing.T) {
	projectID := int64(30)
	devID := int64(301)
	resolver := stubRuleResolver{
		projectByTitle: map[string]*int64{
			"project a": &projectID,
		},
		activityByKey: map[string]*int64{
			activityKey(projectID, "development"): &devID,
		},
	}
	rule := Rule{
		ActionType:         RuleActionAssignProjectAndActivityByT,
		ActionProjectTitle: "project a",
		ActionActivityName: "development",
	}
	target, err := rule.ResolveTarget(RuleContext{}, resolver)
	if err != nil {
		t.Fatalf("resolve target returned error: %v", err)
	}
	if target == nil {
		t.Fatalf("expected resolved target")
	}
	if target.ProjectID != projectID || target.ActivityID != devID {
		t.Fatalf("unexpected target %+v", target)
	}
}

func TestMatchEventToRulesWithResolverUsesActionPriority(t *testing.T) {
	currentProjectID := int64(10)
	developmentID := int64(100)
	meetingID := int64(101)
	resolver := stubRuleResolver{
		activityByKey: map[string]*int64{
			activityKey(currentProjectID, "meeting"): &meetingID,
		},
	}

	rules := []Rule{
		{
			ID:                 1,
			Priority:           250,
			AppPattern:         "(?i)^(Firefox|Arc|Google Chrome|Chrome|Safari)$",
			TitlePattern:       "(?i)^.*(teams|zoom).*$",
			ActionType:         RuleActionAssignActivityCurrent,
			ActionActivityName: "meeting",
		},
		{
			ID:           2,
			Priority:     100,
			AppPattern:   "(?i)^(Firefox|Arc|Google Chrome|Chrome|Safari)$",
			TitlePattern: matchAnyRegex,
			ProjectID:    &currentProjectID,
			ActivityID:   &developmentID,
		},
	}
	events := []Event{
		{ID: 1, TimestampMS: 1, AppName: "Firefox", WindowTitle: "Daily Teams Sync"},
	}

	updates, skipped, err := MatchEventToRulesWithResolver(events, rules, &currentProjectID, resolver)
	if err != nil {
		t.Fatalf("match returned error: %v", err)
	}
	if skipped != 0 {
		t.Fatalf("expected no skipped events, got %d", skipped)
	}
	if len(updates) != 1 {
		t.Fatalf("expected one update, got %d", len(updates))
	}
	if updates[0].ProjectID != currentProjectID || updates[0].ActivityID != meetingID {
		t.Fatalf("unexpected target %+v", updates[0])
	}
}

func TestDefaultBrowserRulesIncludesExpectedKeys(t *testing.T) {
	defaults := DefaultBrowserRules()
	if len(defaults) != 3 {
		t.Fatalf("expected 3 default rules, got %d", len(defaults))
	}
	if defaults[0].RuleKey != "default.browser.project_a_development" {
		t.Fatalf("unexpected first key: %s", defaults[0].RuleKey)
	}
	if defaults[1].RuleKey != "default.browser.meeting_current_project" {
		t.Fatalf("unexpected second key: %s", defaults[1].RuleKey)
	}
	if defaults[2].RuleKey != "default.browser.follow_current_context" {
		t.Fatalf("unexpected third key: %s", defaults[2].RuleKey)
	}
}

func TestBuildRegexRuleFromGroups(t *testing.T) {
	appPattern, titlePattern, err := BuildRegexRuleFromGroups([]GroupedEvent{
		{AppName: "Firefox", WindowTitle: "Project Name A - Browser"},
		{AppName: "Arc", WindowTitle: "Teams Meeting"},
	})
	if err != nil {
		t.Fatalf("build regex rule returned error: %v", err)
	}
	if appPattern != "(?i)^(?:Arc|Firefox)$" {
		t.Fatalf("unexpected app pattern: %s", appPattern)
	}
	if titlePattern != "(?i)^(?:Project Name A - Browser|Teams Meeting)$" {
		t.Fatalf("unexpected title pattern: %s", titlePattern)
	}
}

func TestBuildDraftPreviewIncludesChangedRows(t *testing.T) {
	projectID := int64(10)
	activityID := int64(100)
	base := []Rule{
		{
			ID:           5,
			Priority:     100,
			AppPattern:   "(?i)^Firefox$",
			TitlePattern: matchAnyRegex,
			ProjectID:    &projectID,
			ActivityID:   &activityID,
		},
	}
	working := []Rule{
		{
			ID:           5,
			Priority:     150,
			AppPattern:   "(?i)^Firefox$",
			TitlePattern: matchAnyRegex,
			ProjectID:    &projectID,
			ActivityID:   &activityID,
		},
		{
			ID:           -1,
			Priority:     300,
			AppPattern:   "(?i)^Arc$",
			TitlePattern: "(?i)^.*teams.*$",
			ActionType:   RuleActionFollowCurrentContext,
		},
	}

	preview := BuildDraftPreview(base, working, []string{"missing activity: meeting"})
	if !preview.HasChanges {
		t.Fatalf("expected preview to report changes")
	}
	if len(preview.Rows) != 2 {
		t.Fatalf("expected 2 rows, got %d", len(preview.Rows))
	}
	if preview.Rows[0].Change != RuleDraftAdded {
		t.Fatalf("expected first row added, got %s", preview.Rows[0].Change)
	}
	if preview.Rows[1].Change != RuleDraftUpdated {
		t.Fatalf("expected second row updated, got %s", preview.Rows[1].Change)
	}
	if len(preview.Warnings) != 1 {
		t.Fatalf("expected one warning")
	}
}

func TestGlobToRegexPattern(t *testing.T) {
	got := GlobToRegexPattern("*project-name-a*")
	if got != "(?i)^.*project-name-a.*$" {
		t.Fatalf("unexpected converted regex: %s", got)
	}
}

func TestRankSuggestionsFiltersLowConfidenceAppOnly(t *testing.T) {
	items := []RuleSuggestion{
		{SuggestionType: SuggestionTypeAppOnly, AppPattern: "Slack", Confidence: 55, ImpactDurationMS: 10},
		{SuggestionType: SuggestionTypeAppOnly, AppPattern: "Code", Confidence: 90, ImpactDurationMS: 20},
	}
	ranked := RankSuggestions(items, 10)
	if len(ranked) != 1 {
		t.Fatalf("expected 1 suggestion after filtering, got %d", len(ranked))
	}
	if ranked[0].AppPattern != "Code" {
		t.Fatalf("expected Code suggestion to remain")
	}
}

func TestMatchSuggestionToEvents(t *testing.T) {
	title := "(?i)^.*standup.*$"
	updates := MatchSuggestionToEvents([]Event{
		{ID: 1, AppName: "Slack", WindowTitle: "daily standup"},
		{ID: 2, AppName: "Code", WindowTitle: "main.go"},
	}, RuleSuggestion{
		AppPattern:   "(?i)^Slack$",
		TitlePattern: &title,
		ProjectID:    10,
		ActivityID:   100,
	})
	if len(updates) != 1 {
		t.Fatalf("expected 1 matched event, got %d", len(updates))
	}
	if updates[0].EventID != 1 {
		t.Fatalf("expected event 1 to match")
	}
}
