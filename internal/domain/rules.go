package domain

import (
	"path/filepath"
	"sort"
	"strings"
)

func NormalizeRuleInput(in RuleInput) RuleInput {
	if in.Priority == 0 {
		in.Priority = 100
	}
	in.AppPattern = orDefaultPattern(in.AppPattern)
	in.TitlePattern = orDefaultPattern(in.TitlePattern)
	if in.FollowPrevious {
		in.ProjectID = nil
		in.ActivityID = nil
	}
	return in
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
		return "*"
	}
	if len(t) > 80 {
		t = t[:80]
	}
	return "*" + t + "*"
}

func MatchEventToRules(events []Event, rules []Rule, currentProjectID *int64) []EventMappingUpdate {
	if len(events) == 0 || len(rules) == 0 {
		return nil
	}
	ordered := make([]Event, len(events))
	copy(ordered, events)
	sort.Slice(ordered, func(i, j int) bool {
		if ordered[i].TimestampMS == ordered[j].TimestampMS {
			return ordered[i].ID < ordered[j].ID
		}
		return ordered[i].TimestampMS < ordered[j].TimestampMS
	})

	updates := make([]EventMappingUpdate, 0)
	var prevProjectID *int64
	var prevActivityID *int64
	for _, event := range ordered {
		rule := findFirstMatchingRule(rules, event, currentProjectID)
		if rule == nil {
			continue
		}
		if rule.FollowPrevious {
			if prevProjectID == nil || prevActivityID == nil {
				continue
			}
			updates = append(updates, EventMappingUpdate{
				EventID:    event.ID,
				ProjectID:  *prevProjectID,
				ActivityID: *prevActivityID,
			})
			continue
		}
		if rule.ProjectID == nil || rule.ActivityID == nil {
			continue
		}
		projectID := *rule.ProjectID
		activityID := *rule.ActivityID
		updates = append(updates, EventMappingUpdate{
			EventID:    event.ID,
			ProjectID:  projectID,
			ActivityID: activityID,
		})
		prevProjectID = &projectID
		prevActivityID = &activityID
	}
	return updates
}

func MatchSuggestionToEvents(events []Event, suggestion RuleSuggestion) []EventMappingUpdate {
	appPattern := orDefaultPattern(suggestion.AppPattern)
	titlePattern := "*"
	if suggestion.TitlePattern != nil {
		titlePattern = orDefaultPattern(*suggestion.TitlePattern)
	}
	updates := make([]EventMappingUpdate, 0)
	for _, event := range events {
		if !matchGlob(appPattern, event.AppName) {
			continue
		}
		if !matchGlob(titlePattern, event.WindowTitle) {
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
		if ruleMatchesEvent(rule, event) {
			return rule
		}
	}
	for idx := range rules {
		rule := &rules[idx]
		if ruleMatchesContext(rule, currentProjectID) {
			continue
		}
		if ruleMatchesEvent(rule, event) {
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

func ruleMatchesEvent(rule *Rule, event Event) bool {
	return matchGlob(orDefaultPattern(rule.AppPattern), event.AppName) && matchGlob(orDefaultPattern(rule.TitlePattern), event.WindowTitle)
}

func orDefaultPattern(v string) string {
	if strings.TrimSpace(v) == "" {
		return "*"
	}
	return v
}

func matchGlob(pattern, value string) bool {
	ok, err := filepath.Match(orDefaultPattern(pattern), value)
	if err != nil {
		return false
	}
	return ok
}
