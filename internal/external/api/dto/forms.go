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
