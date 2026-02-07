package domain

import "testing"

func TestNormalizeRuleInputDefaults(t *testing.T) {
	in := NormalizeRuleInput(RuleInput{})
	if in.Priority != 100 {
		t.Fatalf("expected default priority 100, got %d", in.Priority)
	}
	if in.AppPattern != "*" || in.TitlePattern != "*" {
		t.Fatalf("expected wildcard defaults, got app=%q title=%q", in.AppPattern, in.TitlePattern)
	}
}

func TestNormalizeRuleInputFollowPreviousClearsTarget(t *testing.T) {
	projectID := int64(10)
	activityID := int64(20)
	in := NormalizeRuleInput(RuleInput{FollowPrevious: true, ProjectID: &projectID, ActivityID: &activityID})
	if in.ProjectID != nil || in.ActivityID != nil {
		t.Fatalf("expected follow-previous rule to clear target IDs")
	}
}

func TestMatchEventToRulesUsesFollowPrevious(t *testing.T) {
	projectID := int64(10)
	activityID := int64(100)
	follower := Rule{ID: 2, Priority: 90, AppPattern: "Slack", TitlePattern: "*", FollowPrevious: true}
	rules := []Rule{
		{ID: 1, Priority: 100, AppPattern: "Code", TitlePattern: "*", ProjectID: &projectID, ActivityID: &activityID},
		follower,
	}
	events := []Event{
		{ID: 1, TimestampMS: 1, AppName: "Code", WindowTitle: "main.go"},
		{ID: 2, TimestampMS: 2, AppName: "Slack", WindowTitle: "standup"},
	}
	updates := MatchEventToRules(events, rules, nil)
	if len(updates) != 2 {
		t.Fatalf("expected 2 updates, got %d", len(updates))
	}
	if updates[1].ProjectID != projectID || updates[1].ActivityID != activityID {
		t.Fatalf("expected follow-previous mapping to reuse previous target")
	}
}

func TestMatchEventToRulesPrefersCurrentProjectContext(t *testing.T) {
	cur := int64(11)
	p10 := int64(10)
	p11 := int64(11)
	a100 := int64(100)
	a110 := int64(110)
	rules := []Rule{
		{ID: 1, Priority: 100, AppPattern: "Code", TitlePattern: "*", ProjectID: &p10, ActivityID: &a100},
		{ID: 2, Priority: 95, AppPattern: "Code", TitlePattern: "*", ProjectID: &p11, ActivityID: &a110},
	}
	events := []Event{{ID: 1, TimestampMS: 1, AppName: "Code", WindowTitle: "main.go"}}
	updates := MatchEventToRules(events, rules, &cur)
	if len(updates) != 1 {
		t.Fatalf("expected 1 update, got %d", len(updates))
	}
	if updates[0].ProjectID != p11 {
		t.Fatalf("expected current-project rule to win, got %d", updates[0].ProjectID)
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
	title := "*standup*"
	updates := MatchSuggestionToEvents([]Event{
		{ID: 1, AppName: "Slack", WindowTitle: "daily standup"},
		{ID: 2, AppName: "Code", WindowTitle: "main.go"},
	}, RuleSuggestion{
		AppPattern:   "Slack",
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
