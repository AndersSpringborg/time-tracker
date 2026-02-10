package dto

import "time-tracker/internal/domain"

type RuleInput struct {
	RuleKey            string `json:"rule_key,omitempty"`
	Source             string `json:"source,omitempty"`
	Priority           int    `json:"priority"`
	AppPattern         string `json:"app_pattern,omitempty"`
	TitlePattern       string `json:"title_pattern,omitempty"`
	ProjectID          *int64 `json:"project_id,omitempty"`
	ActivityID         *int64 `json:"activity_id,omitempty"`
	FollowPrevious     bool   `json:"follow_previous"`
	ActionType         string `json:"action_type,omitempty"`
	ActionProjectTitle string `json:"action_project_title,omitempty"`
	ActionActivityName string `json:"action_activity_name,omitempty"`
}

func (d RuleInput) ToDomain() domain.RuleInput {
	return domain.RuleInput{
		RuleKey:            d.RuleKey,
		Source:             domain.RuleSource(d.Source),
		Priority:           d.Priority,
		AppPattern:         d.AppPattern,
		TitlePattern:       d.TitlePattern,
		ProjectID:          d.ProjectID,
		ActivityID:         d.ActivityID,
		FollowPrevious:     d.FollowPrevious,
		ActionType:         domain.RuleAction(d.ActionType),
		ActionProjectTitle: d.ActionProjectTitle,
		ActionActivityName: d.ActionActivityName,
	}
}

type SuggestionInput struct {
	SuggestionType     string   `json:"suggestion_type"`
	AppPattern         string   `json:"app_pattern"`
	TitlePattern       *string  `json:"title_pattern,omitempty"`
	ProjectID          int64    `json:"project_id"`
	ActivityID         int64    `json:"activity_id"`
	ProjectTitle       string   `json:"project_title,omitempty"`
	ActivityTitle      string   `json:"activity_title,omitempty"`
	ActionType         string   `json:"action_type,omitempty"`
	ActionActivityName string   `json:"action_activity_name,omitempty"`
	DisplayPath        string   `json:"display_path,omitempty"`
	Confidence         int      `json:"confidence,omitempty"`
	Score              float64  `json:"score,omitempty"`
	ConfidenceReason   string   `json:"confidence_reason,omitempty"`
	Ambiguity          float64  `json:"ambiguity,omitempty"`
	ImpactCount        int      `json:"impact_count,omitempty"`
	ImpactDurationMS   int64    `json:"impact_duration_ms,omitempty"`
	EvidenceCount      int      `json:"evidence_count,omitempty"`
	LastSeenMS         int64    `json:"last_seen_ms,omitempty"`
	ContextHints       []string `json:"context_hints,omitempty"`
}

func (d SuggestionInput) ToDomain() domain.RuleSuggestion {
	return domain.RuleSuggestion{
		SuggestionType:     domain.SuggestionType(d.SuggestionType),
		AppPattern:         d.AppPattern,
		TitlePattern:       d.TitlePattern,
		ProjectID:          d.ProjectID,
		ActivityID:         d.ActivityID,
		ProjectTitle:       d.ProjectTitle,
		ActivityTitle:      d.ActivityTitle,
		ActionType:         domain.RuleAction(d.ActionType),
		ActionActivityName: d.ActionActivityName,
		DisplayPath:        d.DisplayPath,
		Confidence:         d.Confidence,
		Score:              d.Score,
		ConfidenceReason:   d.ConfidenceReason,
		Ambiguity:          d.Ambiguity,
		ImpactCount:        d.ImpactCount,
		ImpactDurationMS:   d.ImpactDurationMS,
		EvidenceCount:      d.EvidenceCount,
		LastSeenMS:         d.LastSeenMS,
		ContextHints:       d.ContextHints,
	}
}
