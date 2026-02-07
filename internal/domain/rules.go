package domain

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
)

const matchAnyRegex = "(?i)^.*$"

func NormalizeRuleInput(in RuleInput) RuleInput {
	if in.Priority == 0 {
		in.Priority = 100
	}
	in.AppPattern = normalizePatternToRegex(in.AppPattern)
	in.TitlePattern = normalizePatternToRegex(in.TitlePattern)
	if in.Source == "" {
		in.Source = RuleSourceUser
	}
	if in.ActionType == "" {
		if in.FollowPrevious {
			in.ActionType = RuleActionFollowCurrentContext
		} else {
			in.ActionType = RuleActionAssignExplicit
		}
	}
	if in.ActionType == RuleActionFollowCurrentContext {
		in.FollowPrevious = true
		in.ProjectID = nil
		in.ActivityID = nil
	}
	if in.ActionType == RuleActionAssignActivityCurrent || in.ActionType == RuleActionAssignProjectAndActivityByT {
		in.FollowPrevious = false
		in.ProjectID = nil
		in.ActivityID = nil
	}
	return in
}

func (r Rule) EffectiveAction() RuleAction {
	if r.ActionType != "" {
		return r.ActionType
	}
	if r.FollowPrevious {
		return RuleActionFollowCurrentContext
	}
	return RuleActionAssignExplicit
}

func (r Rule) Matches(event Event) bool {
	appPattern := normalizePatternToRegex(r.AppPattern)
	titlePattern := normalizePatternToRegex(r.TitlePattern)
	return matchRegex(appPattern, event.AppName) && matchRegex(titlePattern, event.WindowTitle)
}

func (r Rule) ResolveTarget(ctx RuleContext, resolver RuleTargetResolver) (*RuleTarget, error) {
	switch r.EffectiveAction() {
	case RuleActionFollowCurrentContext:
		if ctx.PreviousProjectID == nil || ctx.PreviousActivityID == nil {
			return nil, nil
		}
		return &RuleTarget{ProjectID: *ctx.PreviousProjectID, ActivityID: *ctx.PreviousActivityID}, nil
	case RuleActionAssignActivityCurrent:
		if resolver == nil {
			return nil, nil
		}
		projectID := ctx.CurrentProjectID
		if ctx.PreviousProjectID != nil {
			projectID = ctx.PreviousProjectID
		}
		if projectID == nil {
			return nil, nil
		}
		activityTitle := strings.TrimSpace(r.ActionActivityName)
		if activityTitle == "" {
			return nil, nil
		}
		activityID, err := resolver.FindActivityIDByTitle(*projectID, activityTitle)
		if err != nil {
			return nil, err
		}
		if activityID == nil {
			return nil, nil
		}
		return &RuleTarget{ProjectID: *projectID, ActivityID: *activityID}, nil
	case RuleActionAssignProjectAndActivityByT:
		if resolver == nil {
			return nil, nil
		}
		projectTitle := strings.TrimSpace(r.ActionProjectTitle)
		activityTitle := strings.TrimSpace(r.ActionActivityName)
		if projectTitle == "" || activityTitle == "" {
			return nil, nil
		}
		projectID, err := resolver.FindProjectIDByTitle(projectTitle)
		if err != nil {
			return nil, err
		}
		if projectID == nil {
			return nil, nil
		}
		activityID, err := resolver.FindActivityIDByTitle(*projectID, activityTitle)
		if err != nil {
			return nil, err
		}
		if activityID == nil {
			return nil, nil
		}
		return &RuleTarget{ProjectID: *projectID, ActivityID: *activityID}, nil
	default:
		if r.ProjectID == nil || r.ActivityID == nil {
			return nil, nil
		}
		return &RuleTarget{ProjectID: *r.ProjectID, ActivityID: *r.ActivityID}, nil
	}
}

func (r Rule) Equals(other Rule) bool {
	return r.RuleKey == other.RuleKey &&
		r.Source == other.Source &&
		r.Priority == other.Priority &&
		r.AppPattern == other.AppPattern &&
		r.TitlePattern == other.TitlePattern &&
		equalInt64Ptr(r.ProjectID, other.ProjectID) &&
		equalInt64Ptr(r.ActivityID, other.ActivityID) &&
		r.FollowPrevious == other.FollowPrevious &&
		r.EffectiveAction() == other.EffectiveAction() &&
		r.ActionProjectTitle == other.ActionProjectTitle &&
		r.ActionActivityName == other.ActionActivityName
}

func (r Rule) DisplayTargetText() string {
	if strings.TrimSpace(r.DisplayTarget) != "" {
		return r.DisplayTarget
	}
	switch r.EffectiveAction() {
	case RuleActionFollowCurrentContext:
		return "Follow current project/activity"
	case RuleActionAssignActivityCurrent:
		if strings.TrimSpace(r.ActionActivityName) == "" {
			return "Current project > (activity unresolved)"
		}
		return fmt.Sprintf("Current project > %s", r.ActionActivityName)
	case RuleActionAssignProjectAndActivityByT:
		if strings.TrimSpace(r.ActionProjectTitle) == "" && strings.TrimSpace(r.ActionActivityName) == "" {
			return "Project/activity by title"
		}
		return fmt.Sprintf("%s > %s", r.ActionProjectTitle, r.ActionActivityName)
	default:
		if r.ProjectID != nil && r.ActivityID != nil {
			return fmt.Sprintf("%d > %d", *r.ProjectID, *r.ActivityID)
		}
		return "Unmapped"
	}
}

func BuildDraftPreview(baseRules []Rule, workingRules []Rule, warnings []string) RuleDraftPreview {
	baseByID := make(map[int64]Rule, len(baseRules))
	for _, base := range baseRules {
		baseByID[base.ID] = base
	}

	working := make([]Rule, len(workingRules))
	copy(working, workingRules)
	sortRules(working)

	rows := make([]RuleDraftRow, 0, len(baseRules)+len(workingRules))
	seenIDs := map[int64]struct{}{}
	hasChanges := false
	for _, rule := range working {
		change := RuleDraftAdded
		if rule.ID > 0 {
			if base, ok := baseByID[rule.ID]; ok {
				seenIDs[rule.ID] = struct{}{}
				if rule.Equals(base) {
					change = RuleDraftUnchanged
				} else {
					change = RuleDraftUpdated
					hasChanges = true
				}
			}
		} else {
			hasChanges = true
		}
		r := rule
		r.DisplayTarget = r.DisplayTargetText()
		rows = append(rows, RuleDraftRow{Rule: r, Change: change})
	}

	for _, base := range baseRules {
		if _, ok := seenIDs[base.ID]; ok {
			continue
		}
		hasChanges = true
		b := base
		b.DisplayTarget = b.DisplayTargetText()
		rows = append(rows, RuleDraftRow{Rule: b, Change: RuleDraftDeleted})
	}

	sort.SliceStable(rows, func(i, j int) bool {
		ri := rows[i]
		rj := rows[j]
		if changeOrder(ri.Change) == changeOrder(rj.Change) {
			if ri.Rule.Priority == rj.Rule.Priority {
				return ri.Rule.ID > rj.Rule.ID
			}
			return ri.Rule.Priority > rj.Rule.Priority
		}
		return changeOrder(ri.Change) < changeOrder(rj.Change)
	})

	return RuleDraftPreview{
		Rows:       rows,
		Warnings:   warnings,
		HasChanges: hasChanges,
	}
}

func DefaultBrowserRules() []RuleInput {
	browserPattern := "(?i)^(Firefox|Arc|Google Chrome|Chrome|Safari)$"
	return []RuleInput{
		{
			RuleKey:            "default.browser.project_a_development",
			Source:             RuleSourceDefault,
			Priority:           300,
			AppPattern:         browserPattern,
			TitlePattern:       "(?i)^.*project-name-a.*$",
			ActionType:         RuleActionAssignProjectAndActivityByT,
			ActionProjectTitle: "project a",
			ActionActivityName: "development",
		},
		{
			RuleKey:            "default.browser.meeting_current_project",
			Source:             RuleSourceDefault,
			Priority:           250,
			AppPattern:         browserPattern,
			TitlePattern:       "(?i)^.*(teams|zoom).*$",
			ActionType:         RuleActionAssignActivityCurrent,
			ActionActivityName: "meeting",
		},
		{
			RuleKey:      "default.browser.follow_current_context",
			Source:       RuleSourceDefault,
			Priority:     100,
			AppPattern:   browserPattern,
			TitlePattern: matchAnyRegex,
			ActionType:   RuleActionFollowCurrentContext,
		},
	}
}

func BuildRegexRuleFromGroups(groups []GroupedEvent) (string, string, error) {
	if len(groups) == 0 {
		return "", "", fmt.Errorf("at least one group is required")
	}
	appSet := map[string]struct{}{}
	titleSet := map[string]struct{}{}
	for _, group := range groups {
		app := strings.TrimSpace(group.AppName)
		if app != "" {
			appSet[app] = struct{}{}
		}
		title := strings.TrimSpace(group.WindowTitle)
		if title != "" {
			titleSet[title] = struct{}{}
		}
	}
	appPattern := toCaseInsensitiveExactRegex(appSet)
	titlePattern := toCaseInsensitiveExactRegex(titleSet)
	return appPattern, titlePattern, nil
}

func GlobToRegexPattern(pattern string) string {
	pattern = strings.TrimSpace(pattern)
	if pattern == "" {
		return matchAnyRegex
	}
	var b strings.Builder
	b.WriteString("(?i)^")
	for _, ch := range pattern {
		switch ch {
		case '*':
			b.WriteString(".*")
		case '?':
			b.WriteByte('.')
		default:
			if strings.ContainsRune(`.+()[]{}^$|\`, ch) {
				b.WriteByte('\\')
			}
			b.WriteRune(ch)
		}
	}
	b.WriteString("$")
	return b.String()
}

func RankSuggestions(items []RuleSuggestion, limit int) []RuleSuggestion {
	filtered := make([]RuleSuggestion, 0, len(items))
	for _, item := range items {
		if item.SuggestionType == SuggestionTypeAppOnly && item.Confidence < 60 {
			continue
		}
		filtered = append(filtered, item)
	}

	sort.Slice(filtered, func(i, j int) bool {
		if filtered[i].ImpactDurationMS == filtered[j].ImpactDurationMS {
			if filtered[i].Confidence == filtered[j].Confidence {
				if filtered[i].ImpactCount == filtered[j].ImpactCount {
					return filtered[i].AppPattern < filtered[j].AppPattern
				}
				return filtered[i].ImpactCount > filtered[j].ImpactCount
			}
			return filtered[i].Confidence > filtered[j].Confidence
		}
		return filtered[i].ImpactDurationMS > filtered[j].ImpactDurationMS
	})
	if limit <= 0 || len(filtered) <= limit {
		return filtered
	}
	return filtered[:limit]
}

func FilterSuggestionsMinConfidence(items []RuleSuggestion, minConfidence int) []RuleSuggestion {
	if minConfidence <= 0 {
		return items
	}
	out := make([]RuleSuggestion, 0, len(items))
	for _, item := range items {
		if item.Confidence >= minConfidence {
			out = append(out, item)
		}
	}
	return out
}

func BuildTitlePattern(title string) string {
	t := strings.TrimSpace(title)
	if t == "" {
		return matchAnyRegex
	}
	if len(t) > 80 {
		t = t[:80]
	}
	return "(?i)^.*" + regexp.QuoteMeta(t) + ".*$"
}

func MatchEventToRules(events []Event, rules []Rule, currentProjectID *int64) []EventMappingUpdate {
	updates, _, _ := MatchEventToRulesWithResolver(events, rules, currentProjectID, nil)
	return updates
}

func MatchEventToRulesWithResolver(events []Event, rules []Rule, currentProjectID *int64, resolver RuleTargetResolver) ([]EventMappingUpdate, int, error) {
	if len(events) == 0 || len(rules) == 0 {
		return nil, 0, nil
	}
	ordered := make([]Event, len(events))
	copy(ordered, events)
	sort.Slice(ordered, func(i, j int) bool {
		if ordered[i].TimestampMS == ordered[j].TimestampMS {
			return ordered[i].ID < ordered[j].ID
		}
		return ordered[i].TimestampMS < ordered[j].TimestampMS
	})

	sortedRules := make([]Rule, len(rules))
	copy(sortedRules, rules)
	sortRules(sortedRules)

	updates := make([]EventMappingUpdate, 0)
	var prevProjectID *int64
	var prevActivityID *int64
	skipped := 0
	for _, event := range ordered {
		rule := findFirstMatchingRule(sortedRules, event, currentProjectID)
		if rule == nil {
			continue
		}
		target, err := rule.ResolveTarget(RuleContext{
			CurrentProjectID:   currentProjectID,
			PreviousProjectID:  prevProjectID,
			PreviousActivityID: prevActivityID,
		}, resolver)
		if err != nil {
			return updates, skipped, err
		}
		if target == nil {
			skipped++
			continue
		}
		updates = append(updates, EventMappingUpdate{
			EventID:    event.ID,
			ProjectID:  target.ProjectID,
			ActivityID: target.ActivityID,
		})
		projectID := target.ProjectID
		activityID := target.ActivityID
		prevProjectID = &projectID
		prevActivityID = &activityID
	}
	return updates, skipped, nil
}

func MatchSuggestionToEvents(events []Event, suggestion RuleSuggestion) []EventMappingUpdate {
	appPattern := normalizePatternToRegex(suggestion.AppPattern)
	titlePattern := matchAnyRegex
	if suggestion.TitlePattern != nil {
		titlePattern = normalizePatternToRegex(*suggestion.TitlePattern)
	}
	updates := make([]EventMappingUpdate, 0)
	for _, event := range events {
		if !matchRegex(appPattern, event.AppName) {
			continue
		}
		if !matchRegex(titlePattern, event.WindowTitle) {
			continue
		}
		updates = append(updates, EventMappingUpdate{
			EventID:    event.ID,
			ProjectID:  suggestion.ProjectID,
			ActivityID: suggestion.ActivityID,
		})
	}
	return updates
}

func findFirstMatchingRule(rules []Rule, event Event, currentProjectID *int64) *Rule {
	for idx := range rules {
		rule := &rules[idx]
		if !ruleMatchesContext(rule, currentProjectID) {
			continue
		}
		if rule.Matches(event) {
			return rule
		}
	}
	for idx := range rules {
		rule := &rules[idx]
		if ruleMatchesContext(rule, currentProjectID) {
			continue
		}
		if rule.Matches(event) {
			return rule
		}
	}
	return nil
}

func ruleMatchesContext(rule *Rule, currentProjectID *int64) bool {
	if currentProjectID == nil {
		return true
	}
	if rule.ProjectID == nil {
		return true
	}
	return *rule.ProjectID == *currentProjectID
}

func normalizePatternToRegex(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return matchAnyRegex
	}

	if strings.ContainsAny(raw, "*?") && !strings.ContainsAny(raw, "()[]{}+|\\") {
		return GlobToRegexPattern(raw)
	}

	if hasRegexMeta(raw) {
		if _, err := regexp.Compile(raw); err == nil {
			return raw
		}
	}

	if _, err := regexp.Compile(raw); err == nil && (strings.HasPrefix(raw, "^") || strings.Contains(raw, "(?i)")) {
		return raw
	}

	return "(?i)^" + regexp.QuoteMeta(raw) + "$"
}

func hasRegexMeta(pattern string) bool {
	return strings.ContainsAny(pattern, ".+()[]{}^$|\\")
}

func matchRegex(pattern, value string) bool {
	re, err := regexp.Compile(pattern)
	if err != nil {
		fallback := GlobToRegexPattern(pattern)
		re, err = regexp.Compile(fallback)
		if err != nil {
			return false
		}
	}
	return re.MatchString(value)
}

func sortRules(rules []Rule) {
	sort.SliceStable(rules, func(i, j int) bool {
		if rules[i].Priority == rules[j].Priority {
			return rules[i].ID > rules[j].ID
		}
		return rules[i].Priority > rules[j].Priority
	})
}

func toCaseInsensitiveExactRegex(values map[string]struct{}) string {
	if len(values) == 0 {
		return matchAnyRegex
	}
	list := make([]string, 0, len(values))
	for value := range values {
		list = append(list, regexp.QuoteMeta(value))
	}
	sort.Strings(list)
	if len(list) == 1 {
		return "(?i)^" + list[0] + "$"
	}
	return "(?i)^(?:" + strings.Join(list, "|") + ")$"
}

func changeOrder(change RuleDraftChange) int {
	switch change {
	case RuleDraftAdded:
		return 0
	case RuleDraftUpdated:
		return 1
	case RuleDraftDeleted:
		return 2
	default:
		return 3
	}
}

func equalInt64Ptr(left, right *int64) bool {
	if left == nil && right == nil {
		return true
	}
	if left == nil || right == nil {
		return false
	}
	return *left == *right
}
