package domain

type Event struct {
	ID           int64
	TimestampMS  int64
	DurationMS   int64
	AppName      string
	WindowTitle  string
	WifiSSID     string
	ProjectID    *int64
	ActivityID   *int64
	ProjectTitle string
	ActivityName string
}

type GroupedEvent struct {
	AppName         string
	WindowTitle     string
	WifiSSID        string
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

type ApplyRulesInput struct {
	Date   *string
	DryRun bool
}

type ApplyRulesResult struct {
	UnmappedEvents int64
	MatchedEvents  int64
}

// GroupedEventMatch represents a group of events with matching rule info for preview
type GroupedEventMatch struct {
	AppName         string
	WindowTitle     string
	WifiSSID        string
	TotalDurationMS int64
	EventCount      int64
	MatchedRule     *Rule  // nil if no rule matched
	TargetDisplay   string // "Project > Activity" or empty if unmatched
}

type EventMappingUpdate struct {
	EventID    int64
	ProjectID  int64
	ActivityID int64
}

type Settings struct {
	WorkWifis             []string
	Enabled               bool
	WeightedSwitchMinutes int64
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

type MappedEventDetail struct {
	TimestampMS int64
	DurationMS  int64
	AppName     string
	WindowTitle string
	WifiSSID    string
}

type ActivityDetail struct {
	ActivityID   int64
	ActivityName string
	TotalMS      int64
	Events       []MappedEventDetail
}

type ProjectDetail struct {
	ProjectID    int64
	ProjectTitle string
	TotalMS      int64
	Activities   []ActivityDetail
}

type Report struct {
	Range          string
	TotalMS        int64
	WorkMS         int64
	TotalEvents    int64
	WorkEvents     int64
	MappedEvents   int64
	UnmappedEvents int64
	MappedMS       int64
	UnmappedMS     int64
	ByProject      []SummaryRow
	ByActivity     []SummaryRow
	ByApp          []SummaryRow
	ByWifi         []SummaryRow
	ByWindow       []SummaryRow
	MappedDetails  []ProjectDetail
}

type Dashboard struct {
	TodayTotalMS     int64
	WorkTodayMS      int64
	TrackedEvents    int64
	WorkEvents       int64
	TopApps          []SummaryRow
	ByProject        []SummaryRow
	ByActivity       []SummaryRow
	CurrentProject   string
	CurrentProjectID *int64
}

type TimelineHourMark struct {
	Hour       int
	Label      string
	TopPercent float64
}

type TimelineEvent struct {
	EventID       int64
	StartLabel    string
	EndLabel      string
	DurationMS    int64
	AppName       string
	WindowTitle   string
	ProjectTitle  string
	ActivityName  string
	WifiSSID      string
	InView        bool
	IsMapped      bool
	TopPercent    float64
	HeightPercent float64
}

type TimelineDay struct {
	Date          string
	StartHour     int
	EndHour       int
	HourMarks     []TimelineHourMark
	Events        []TimelineEvent
	TotalEvents   int64
	VisibleEvents int64
	TotalMS       int64
	VisibleMS     int64
}

type LifecycleStatus struct {
	Loaded bool
	PID    string
	State  string
	Raw    string
}
