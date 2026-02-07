package contracts

import (
	tidsregmodel "time-tracker/internal/application/integrations/tidsreg"
	"time-tracker/internal/domain"
)

type RulesListRequest struct{}
type RulesListResponse struct {
	Rules []domain.Rule
}

type RulesAddRequest struct {
	Rule domain.RuleInput
}
type RulesAddResponse struct {
	RuleID int64
}

type RulesDeleteRequest struct {
	RuleID int64
}
type RulesDeleteResponse struct{}

type RulesDraftAddRequest struct {
	Rule domain.RuleInput
}
type RulesDraftAddResponse struct{}

type RulesDraftAddFromGroupsRequest struct {
	Groups []domain.GroupedEvent
	Rule   domain.RuleInput
}
type RulesDraftAddFromGroupsResponse struct{}

type RulesDraftDeleteRequest struct {
	RuleID int64
}
type RulesDraftDeleteResponse struct{}

type RulesDraftReAddDefaultsRequest struct{}
type RulesDraftReAddDefaultsResponse struct {
	Warnings []string
}

type RulesDraftPreviewRequest struct{}
type RulesDraftPreviewResponse struct {
	Preview domain.RuleDraftPreview
}

type RulesDraftSaveRequest struct{}
type RulesDraftSaveResponse struct {
	Result domain.RulesetApplyResult
}

type RulesDraftDiscardRequest struct{}
type RulesDraftDiscardResponse struct{}

type RulesUnmappedDatesRequest struct {
	MinDurationMS int64
}
type RulesUnmappedDatesResponse struct {
	Dates []string
}

type RulesUnmappedGroupsRequest struct {
	Date          string
	MinDurationMS int64
}
type RulesUnmappedGroupsResponse struct {
	Groups []domain.GroupedEvent
}

type RulesAnalyzeSuggestionsRequest struct {
	Query domain.SuggestionQuery
}
type RulesAnalyzeSuggestionsResponse struct {
	Suggestions []domain.RuleSuggestion
}

type RulesAcceptSuggestionRequest struct {
	Input domain.ApplySuggestionInput
}
type RulesAcceptSuggestionResponse struct {
	Result domain.ApplySuggestionResult
}

type RulesAutoApplySuggestionsRequest struct {
	Input domain.AutoApplySuggestionsInput
}
type RulesAutoApplySuggestionsResponse struct {
	Result domain.AutoApplySuggestionsResult
}

type RulesApplyRequest struct {
	Input domain.ApplyRulesInput
}
type RulesApplyResponse struct {
	Result domain.ApplyRulesResult
}

type ReportsDashboardRequest struct{}
type ReportsDashboardResponse struct {
	Dashboard domain.Dashboard
}

type ReportsBuildRequest struct {
	RangeKey string
	Date     *string
}
type ReportsBuildResponse struct {
	Report domain.Report
}

type ProjectsListActiveRequest struct{}
type ProjectsListActiveResponse struct {
	Projects []domain.Project
}

type ProjectsListAllRequest struct{}
type ProjectsListAllResponse struct {
	Projects []domain.Project
}

type ProjectsActivateRequest struct {
	ProjectID int64
}
type ProjectsActivateResponse struct{}

type ProjectsEndRequest struct {
	ProjectID int64
}
type ProjectsEndResponse struct{}

type ProjectsEndAllRequest struct{}
type ProjectsEndAllResponse struct{}

type ProjectsCurrentRequest struct{}
type ProjectsCurrentResponse struct {
	Name      string
	ProjectID *int64
}

type SettingsLoadRequest struct{}
type SettingsLoadResponse struct {
	Settings domain.Settings
	Path     string
}

type SettingsSaveRequest struct {
	Settings domain.Settings
}
type SettingsSaveResponse struct {
	Path string
}

type LifecycleInstallRequest struct{}
type LifecycleInstallResponse struct{}

type LifecycleUninstallRequest struct{}
type LifecycleUninstallResponse struct{}

type LifecycleStartRequest struct{}
type LifecycleStartResponse struct{}

type LifecycleStopRequest struct{}
type LifecycleStopResponse struct{}

type LifecycleStatusRequest struct{}
type LifecycleStatusResponse struct {
	Status domain.LifecycleStatus
}

type ReviewDatesRequest struct {
	MinDurationMS int64
}
type ReviewDatesResponse struct {
	Dates []string
}

type ReviewGroupsRequest struct {
	Date          string
	MinDurationMS int64
}
type ReviewGroupsResponse struct {
	Groups []domain.GroupedEvent
}

type ReviewMapGroupRequest struct {
	Date        string
	AppName     string
	WindowTitle string
	ProjectID   int64
	ActivityID  int64
}
type ReviewMapGroupResponse struct {
	Mapped int64
}

type ReviewDiscardGroupRequest struct {
	Date        string
	AppName     string
	WindowTitle string
}
type ReviewDiscardGroupResponse struct {
	Discarded int64
}

type HelpCommandSchema struct {
	Command     string
	Description string
	Usage       string
	Flags       []string
	Examples    []string
	SideEffects []string
}

type HelpGetSchemaRequest struct {
	Command string
}
type HelpGetSchemaResponse struct {
	Schema HelpCommandSchema
}

type HelpListSchemasRequest struct{}
type HelpListSchemasResponse struct {
	Schemas []HelpCommandSchema
}

type TidsregAuthenticateRequest struct {
	Username string
	Password string
	Mode     tidsregmodel.Mode
}
type TidsregAuthenticateResponse struct {
	SessionCookie string
	Customers     []tidsregmodel.Customer
}

type TidsregBuildPreviewRequest struct {
	SessionCookie       string
	Mode                tidsregmodel.Mode
	Customers           []tidsregmodel.Customer
	SelectedCustomerIDs []int64
}
type TidsregBuildPreviewResponse struct {
	Preview tidsregmodel.ImportPreview
}

type TidsregCommitRequest struct {
	Preview      tidsregmodel.ImportPreview
	SelectedKeys []string
}
type TidsregCommitResponse struct {
	Result tidsregmodel.ImportResult
}
