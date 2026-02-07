package domain

type Event struct {
	ID           int64  `json:"id"`
	TimestampMS  int64  `json:"timestamp_ms"`
	DurationMS   int64  `json:"duration_ms"`
	AppName      string `json:"app_name"`
	WindowTitle  string `json:"window_title"`
	ProjectID    *int64 `json:"project_id,omitempty"`
	ActivityID   *int64 `json:"activity_id,omitempty"`
	ProjectTitle string `json:"project_title,omitempty"`
}

type GroupedEvent struct {
	AppName         string `json:"app_name"`
	WindowTitle     string `json:"window_title"`
	TotalDurationMS int64  `json:"total_duration_ms"`
	EventCount      int64  `json:"event_count"`
}

type Activity struct {
	ActivityID int64  `json:"activity_id"`
	ProjectID  int64  `json:"project_id"`
	Title      string `json:"title"`
}

type Rule struct {
	ID                 int64      `json:"id"`
	RuleKey            string     `json:"rule_key,omitempty"`
	Source             RuleSource `json:"source,omitempty"`
	Priority           int        `json:"priority"`
	AppPattern         string     `json:"app_pattern,omitempty"`
	TitlePattern       string     `json:"title_pattern,omitempty"`
	ProjectID          *int64     `json:"project_id,omitempty"`
	ActivityID         *int64     `json:"activity_id,omitempty"`
	FollowPrevious     bool       `json:"follow_previous"`
	ActionType         RuleAction `json:"action_type,omitempty"`
	ActionProjectTitle string     `json:"action_project_title,omitempty"`
	ActionActivityName string     `json:"action_activity_name,omitempty"`
	DisplayTarget      string     `json:"display_target,omitempty"`
}

type RuleInput struct {
	RuleKey            string
	Source             RuleSource
	Priority           int
	AppPattern         string
	TitlePattern       string
	ProjectID          *int64
	ActivityID         *int64
	FollowPrevious     bool
	ActionType         RuleAction
	ActionProjectTitle string
	ActionActivityName string
}

type RuleSource string

const (
	RuleSourceUser    RuleSource = "user"
	RuleSourceDefault RuleSource = "default"
)

type RuleAction string

const (
	RuleActionAssignExplicit              RuleAction = "assign_explicit"
	RuleActionFollowCurrentContext        RuleAction = "follow_current_context"
	RuleActionAssignActivityCurrent       RuleAction = "assign_activity_in_current_project"
	RuleActionAssignProjectAndActivityByT RuleAction = "assign_project_activity_by_title"
)

type RuleContext struct {
	CurrentProjectID   *int64
	PreviousProjectID  *int64
	PreviousActivityID *int64
}

type RuleTarget struct {
	ProjectID  int64
	ActivityID int64
}

type RuleTargetResolver interface {
	FindProjectIDByTitle(title string) (*int64, error)
	FindActivityIDByTitle(projectID int64, activityTitle string) (*int64, error)
}

type RuleDraftChange string

const (
	RuleDraftUnchanged RuleDraftChange = "unchanged"
	RuleDraftAdded     RuleDraftChange = "added"
	RuleDraftUpdated   RuleDraftChange = "updated"
	RuleDraftDeleted   RuleDraftChange = "deleted"
)

type RuleDraftRow struct {
	Rule   Rule
	Change RuleDraftChange
}

type RuleDraftPreview struct {
	Rows       []RuleDraftRow
	Warnings   []string
	HasChanges bool
}

type RulesetChanges struct {
	Adds    []RuleInput
	Updates []RuleUpdate
	Deletes []int64
}

type RuleUpdate struct {
	ID   int64
	Rule RuleInput
}

type RulesetApplyResult struct {
	Added   int
	Updated int
	Deleted int
}

type SuggestionType string

const (
	SuggestionTypeAppOnly     SuggestionType = "app_only"
	SuggestionTypeAppAndTitle SuggestionType = "app_and_title"
)

type RuleSuggestion struct {
	SuggestionType   SuggestionType `json:"suggestion_type"`
	AppPattern       string         `json:"app_pattern"`
	TitlePattern     *string        `json:"title_pattern,omitempty"`
	ProjectID        int64          `json:"project_id"`
	ActivityID       int64          `json:"activity_id"`
	DisplayPath      string         `json:"display_path"`
	Confidence       int            `json:"confidence"`
	ImpactCount      int            `json:"impact_count"`
	ImpactDurationMS int64          `json:"impact_duration_ms"`
	EvidenceCount    int            `json:"evidence_count"`
}

type SuggestionQuery struct {
	Date          *string
	MinDurationMS int64
	Limit         int
}

type ApplySuggestionInput struct {
	Suggestion RuleSuggestion
	ApplyNow   bool
	Date       *string
}

type ApplySuggestionResult struct {
	RuleCreated  bool  `json:"rule_created"`
	MappedEvents int64 `json:"mapped_events"`
}

type AutoApplySuggestionsInput struct {
	Date          *string
	MinDurationMS int64
	MinConfidence int
	ApplyNow      bool
	Limit         int
}

type AutoApplySuggestionsResult struct {
	Analyzed     int   `json:"analyzed"`
	Accepted     int   `json:"accepted"`
	MappedEvents int64 `json:"mapped_events"`
}

type ApplyRulesInput struct {
	Date   *string
	DryRun bool
}

type ApplyRulesResult struct {
	UnmappedEvents int64 `json:"unmapped_events"`
	MatchedEvents  int64 `json:"matched_events"`
}

type EventMappingUpdate struct {
	EventID    int64
	ProjectID  int64
	ActivityID int64
}

type Settings struct {
	WorkWifis             []string `json:"work_wifis"`
	Enabled               bool     `json:"enabled"`
	WeightedBucketMinutes int64    `json:"weighted_bucket_minutes"`
	WeightedSwitchMinutes int64    `json:"weighted_switch_minutes"`
	NoiseAppPatterns      []string `json:"noise_app_patterns"`
	NoiseBucketMinutes    int64    `json:"noise_bucket_minutes"`
	NoiseSwitchMinutes    int64    `json:"noise_switch_minutes"`
}

type Project struct {
	ProjectID int64  `json:"project_id"`
	Title     string `json:"title"`
	Metadata  string `json:"metadata,omitempty"`
}

type SummaryRow struct {
	Name    string `json:"name"`
	TotalMS int64  `json:"total_ms"`
}

type Report struct {
	Range          string       `json:"range"`
	TotalMS        int64        `json:"total_ms"`
	ExcludedEvents int          `json:"excluded_events"`
	ByProject      []SummaryRow `json:"by_project"`
	ByApp          []SummaryRow `json:"by_app"`
}

type Dashboard struct {
	TodayTotalMS     int64        `json:"today_total_ms"`
	TrackedEvents    int64        `json:"tracked_events"`
	ExcludedEvents   int64        `json:"excluded_events"`
	TopApps          []SummaryRow `json:"top_apps"`
	CurrentProject   string       `json:"current_project"`
	CurrentProjectID *int64       `json:"current_project_id,omitempty"`
}

type LifecycleStatus struct {
	Loaded bool   `json:"loaded"`
	PID    string `json:"pid,omitempty"`
	State  string `json:"state"`
	Raw    string `json:"raw,omitempty"`
}
