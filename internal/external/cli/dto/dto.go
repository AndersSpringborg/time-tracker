package dto

import (
	"time-tracker/internal/application/contracts"
	"time-tracker/internal/domain"
)

type CommandSchema struct {
	Command     string   `json:"command" yaml:"command"`
	Description string   `json:"description" yaml:"description"`
	Usage       string   `json:"usage" yaml:"usage"`
	Flags       []string `json:"flags" yaml:"flags"`
	Examples    []string `json:"examples" yaml:"examples"`
	SideEffects []string `json:"side_effects" yaml:"side_effects"`
}

type Rule struct {
	ID                 int64  `json:"id" yaml:"id"`
	RuleKey            string `json:"rule_key,omitempty" yaml:"rule_key,omitempty"`
	Source             string `json:"source,omitempty" yaml:"source,omitempty"`
	Priority           int    `json:"priority" yaml:"priority"`
	AppPattern         string `json:"app_pattern,omitempty" yaml:"app_pattern,omitempty"`
	TitlePattern       string `json:"title_pattern,omitempty" yaml:"title_pattern,omitempty"`
	ProjectID          *int64 `json:"project_id,omitempty" yaml:"project_id,omitempty"`
	ActivityID         *int64 `json:"activity_id,omitempty" yaml:"activity_id,omitempty"`
	FollowPrevious     bool   `json:"follow_previous" yaml:"follow_previous"`
	ActionType         string `json:"action_type,omitempty" yaml:"action_type,omitempty"`
	ActionProjectTitle string `json:"action_project_title,omitempty" yaml:"action_project_title,omitempty"`
	ActionActivityName string `json:"action_activity_name,omitempty" yaml:"action_activity_name,omitempty"`
	DisplayTarget      string `json:"display_target,omitempty" yaml:"display_target,omitempty"`
}

type RuleSuggestion struct {
	SuggestionType   string  `json:"suggestion_type" yaml:"suggestion_type"`
	AppPattern       string  `json:"app_pattern" yaml:"app_pattern"`
	TitlePattern     *string `json:"title_pattern,omitempty" yaml:"title_pattern,omitempty"`
	ProjectID        int64   `json:"project_id" yaml:"project_id"`
	ActivityID       int64   `json:"activity_id" yaml:"activity_id"`
	DisplayPath      string  `json:"display_path" yaml:"display_path"`
	Confidence       int     `json:"confidence" yaml:"confidence"`
	ImpactCount      int     `json:"impact_count" yaml:"impact_count"`
	ImpactDurationMS int64   `json:"impact_duration_ms" yaml:"impact_duration_ms"`
	EvidenceCount    int     `json:"evidence_count" yaml:"evidence_count"`
}

type AutoApplySuggestionsResult struct {
	Analyzed     int   `json:"analyzed" yaml:"analyzed"`
	Accepted     int   `json:"accepted" yaml:"accepted"`
	MappedEvents int64 `json:"mapped_events" yaml:"mapped_events"`
}

type ApplyRulesResult struct {
	UnmappedEvents int64 `json:"unmapped_events" yaml:"unmapped_events"`
	MatchedEvents  int64 `json:"matched_events" yaml:"matched_events"`
}

type Project struct {
	ProjectID int64  `json:"project_id" yaml:"project_id"`
	Title     string `json:"title" yaml:"title"`
	Metadata  string `json:"metadata,omitempty" yaml:"metadata,omitempty"`
}

type Settings struct {
	WorkWifis             []string `json:"work_wifis" yaml:"work_wifis"`
	Enabled               bool     `json:"enabled" yaml:"enabled"`
	WeightedBucketMinutes int64    `json:"weighted_bucket_minutes" yaml:"weighted_bucket_minutes"`
	WeightedSwitchMinutes int64    `json:"weighted_switch_minutes" yaml:"weighted_switch_minutes"`
	NoiseAppPatterns      []string `json:"noise_app_patterns" yaml:"noise_app_patterns"`
	NoiseBucketMinutes    int64    `json:"noise_bucket_minutes" yaml:"noise_bucket_minutes"`
	NoiseSwitchMinutes    int64    `json:"noise_switch_minutes" yaml:"noise_switch_minutes"`
}

type GroupedEvent struct {
	AppName         string `json:"app_name" yaml:"app_name"`
	WindowTitle     string `json:"window_title" yaml:"window_title"`
	TotalDurationMS int64  `json:"total_duration_ms" yaml:"total_duration_ms"`
	EventCount      int64  `json:"event_count" yaml:"event_count"`
}

type SummaryRow struct {
	Name    string `json:"name" yaml:"name"`
	TotalMS int64  `json:"total_ms" yaml:"total_ms"`
}

type Report struct {
	Range          string       `json:"range" yaml:"range"`
	TotalMS        int64        `json:"total_ms" yaml:"total_ms"`
	ExcludedEvents int          `json:"excluded_events" yaml:"excluded_events"`
	ByProject      []SummaryRow `json:"by_project" yaml:"by_project"`
	ByApp          []SummaryRow `json:"by_app" yaml:"by_app"`
}

func SchemaFromContract(in contracts.HelpCommandSchema) CommandSchema {
	return CommandSchema{
		Command:     in.Command,
		Description: in.Description,
		Usage:       in.Usage,
		Flags:       in.Flags,
		Examples:    in.Examples,
		SideEffects: in.SideEffects,
	}
}

func SchemasFromContracts(items []contracts.HelpCommandSchema) []CommandSchema {
	out := make([]CommandSchema, 0, len(items))
	for _, item := range items {
		out = append(out, SchemaFromContract(item))
	}
	return out
}

func RulesFromDomain(items []domain.Rule) []Rule {
	out := make([]Rule, 0, len(items))
	for _, item := range items {
		out = append(out, Rule{
			ID:                 item.ID,
			RuleKey:            item.RuleKey,
			Source:             string(item.Source),
			Priority:           item.Priority,
			AppPattern:         item.AppPattern,
			TitlePattern:       item.TitlePattern,
			ProjectID:          item.ProjectID,
			ActivityID:         item.ActivityID,
			FollowPrevious:     item.FollowPrevious,
			ActionType:         string(item.ActionType),
			ActionProjectTitle: item.ActionProjectTitle,
			ActionActivityName: item.ActionActivityName,
			DisplayTarget:      item.DisplayTarget,
		})
	}
	return out
}

func SuggestionsFromDomain(items []domain.RuleSuggestion) []RuleSuggestion {
	out := make([]RuleSuggestion, 0, len(items))
	for _, item := range items {
		out = append(out, RuleSuggestion{
			SuggestionType:   string(item.SuggestionType),
			AppPattern:       item.AppPattern,
			TitlePattern:     item.TitlePattern,
			ProjectID:        item.ProjectID,
			ActivityID:       item.ActivityID,
			DisplayPath:      item.DisplayPath,
			Confidence:       item.Confidence,
			ImpactCount:      item.ImpactCount,
			ImpactDurationMS: item.ImpactDurationMS,
			EvidenceCount:    item.EvidenceCount,
		})
	}
	return out
}

func AutoApplyResultFromDomain(in domain.AutoApplySuggestionsResult) AutoApplySuggestionsResult {
	return AutoApplySuggestionsResult{Analyzed: in.Analyzed, Accepted: in.Accepted, MappedEvents: in.MappedEvents}
}

func ApplyRulesResultFromDomain(in domain.ApplyRulesResult) ApplyRulesResult {
	return ApplyRulesResult{UnmappedEvents: in.UnmappedEvents, MatchedEvents: in.MatchedEvents}
}

func ProjectsFromDomain(items []domain.Project) []Project {
	out := make([]Project, 0, len(items))
	for _, item := range items {
		out = append(out, Project{ProjectID: item.ProjectID, Title: item.Title, Metadata: item.Metadata})
	}
	return out
}

func SettingsFromDomain(in domain.Settings) Settings {
	return Settings{
		WorkWifis:             in.WorkWifis,
		Enabled:               in.Enabled,
		WeightedBucketMinutes: in.WeightedBucketMinutes,
		WeightedSwitchMinutes: in.WeightedSwitchMinutes,
		NoiseAppPatterns:      in.NoiseAppPatterns,
		NoiseBucketMinutes:    in.NoiseBucketMinutes,
		NoiseSwitchMinutes:    in.NoiseSwitchMinutes,
	}
}

func GroupedEventsFromDomain(items []domain.GroupedEvent) []GroupedEvent {
	out := make([]GroupedEvent, 0, len(items))
	for _, item := range items {
		out = append(out, GroupedEvent{
			AppName:         item.AppName,
			WindowTitle:     item.WindowTitle,
			TotalDurationMS: item.TotalDurationMS,
			EventCount:      item.EventCount,
		})
	}
	return out
}

func ReportFromDomain(in domain.Report) Report {
	toSummary := func(items []domain.SummaryRow) []SummaryRow {
		out := make([]SummaryRow, 0, len(items))
		for _, item := range items {
			out = append(out, SummaryRow{Name: item.Name, TotalMS: item.TotalMS})
		}
		return out
	}
	return Report{
		Range:          in.Range,
		TotalMS:        in.TotalMS,
		ExcludedEvents: in.ExcludedEvents,
		ByProject:      toSummary(in.ByProject),
		ByApp:          toSummary(in.ByApp),
	}
}
