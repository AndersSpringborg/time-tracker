package domain

type Event struct {
	ID           int64
	TimestampMS  int64
	DurationMS   int64
	AppName      string
	WindowTitle  string
	ProjectID    *int64
	ActivityID   *int64
	ProjectTitle string
}

type GroupedEvent struct {
	AppName         string
	WindowTitle     string
	TotalDurationMS int64
	EventCount      int64
}

type Activity struct {
	ActivityID int64
	ProjectID  int64
	Title      string
}

type Rule struct {
	ID                 int64
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
	DisplayTarget      string
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

type RuleAssignmentTarget struct {
	ProjectTitle  string
	ActivityTitle string
}

func (t RuleAssignmentTarget) DisplayPath() string {
	if t.ProjectTitle == "" {
		return t.ActivityTitle
	}
	if t.ActivityTitle == "" {
		return t.ProjectTitle
	}
	return t.ProjectTitle + " > " + t.ActivityTitle
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

type SuggestionFeedbackAction string

const (
	SuggestionFeedbackAccepted SuggestionFeedbackAction = "accepted"
	SuggestionFeedbackRejected SuggestionFeedbackAction = "rejected"
	SuggestionFeedbackIgnored  SuggestionFeedbackAction = "ignored"
)

type RuleSuggestion struct {
	SuggestionType   SuggestionType
	AppPattern       string
	TitlePattern     *string
	ProjectID        int64
	ActivityID       int64
	DisplayPath      string
	Confidence       int
	Score            float64
	ConfidenceReason string
	Ambiguity        float64
	ImpactCount      int
	ImpactDurationMS int64
	EvidenceCount    int
	LastSeenMS       int64
	ContextHints     []string
}

type SuggestionQuery struct {
	Date           *string
	MinDurationMS  int64
	Limit          int
	MinEvidence    int
	IncludeContext bool
	ExcludeApps    []string
}

type SuggestionStats struct {
	MappedEvents int64
	Activities   int64
	IsColdStart  bool
	Message      string
}

type SuggestionFeedback struct {
	SuggestionType SuggestionType
	AppPattern     string
	TitlePattern   *string
	ProjectID      int64
	ActivityID     int64
	Score          float64
	Confidence     int
	Action         SuggestionFeedbackAction
	AppliedNow     bool
	DateScope      *string
}

type SuggestionRun struct {
	DateScope      *string
	MinDurationMS  int64
	Limit          int
	MinEvidence    int
	MinConfidence  int
	IncludeContext bool
	ApplyNow       bool
	Analyzed       int
	Accepted       int
	MappedEvents   int64
}

type BootstrapLabelInput struct {
	Date        string
	AppName     string
	WindowTitle string
	ProjectID   int64
	ActivityID  int64
	CreateRule  bool
	ApplyNow    bool
}

type BootstrapLabelResult struct {
	MappedEvents int64
	RuleCreated  bool
}

type ApplySuggestionInput struct {
	Suggestion RuleSuggestion
	ApplyNow   bool
	Date       *string
}

type ApplySuggestionResult struct {
	RuleCreated  bool
	MappedEvents int64
}

type AutoApplySuggestionsInput struct {
	Date          *string
	MinDurationMS int64
	MinConfidence int
	ApplyNow      bool
	Limit         int
}

type AutoApplySuggestionsResult struct {
	Analyzed     int
	Accepted     int
	MappedEvents int64
}

type ApplyRulesInput struct {
	Date   *string
	DryRun bool
}

type ApplyRulesResult struct {
	UnmappedEvents int64
	MatchedEvents  int64
}

type EventMappingUpdate struct {
	EventID    int64
	ProjectID  int64
	ActivityID int64
}

type Settings struct {
	WorkWifis             []string
	Enabled               bool
	WeightedBucketMinutes int64
	WeightedSwitchMinutes int64
	NoiseAppPatterns      []string
	NoiseBucketMinutes    int64
	NoiseSwitchMinutes    int64
}

type Project struct {
	ProjectID int64
	Title     string
	Metadata  string
}

type SummaryRow struct {
	Name    string
	TotalMS int64
}

type Report struct {
	Range          string
	TotalMS        int64
	ExcludedEvents int
	ByProject      []SummaryRow
	ByApp          []SummaryRow
}

type Dashboard struct {
	TodayTotalMS     int64
	TrackedEvents    int64
	ExcludedEvents   int64
	TopApps          []SummaryRow
	CurrentProject   string
	CurrentProjectID *int64
}

type LifecycleStatus struct {
	Loaded bool
	PID    string
	State  string
	Raw    string
}
