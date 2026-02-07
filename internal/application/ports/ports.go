package ports

import (
	"context"

	"time-tracker/internal/domain"
)

type RulesRepository interface {
	ListRules(ctx context.Context) ([]domain.Rule, error)
	AddRule(ctx context.Context, in domain.RuleInput) (int64, error)
	UpdateRule(ctx context.Context, id int64, in domain.RuleInput) error
	DeleteRule(ctx context.Context, id int64) error
	ApplyRulesetChanges(ctx context.Context, in domain.RulesetChanges) (domain.RulesetApplyResult, error)
	ListUnmappedEvents(ctx context.Context, date *string, minDurationMS int64) ([]domain.Event, error)
	ListUnmappedDates(ctx context.Context, minDurationMS int64) ([]string, error)
	ListGroupedUnmappedEvents(ctx context.Context, date string, minDurationMS int64) ([]domain.GroupedEvent, error)
	ListAppSuggestions(ctx context.Context, q domain.SuggestionQuery) ([]domain.RuleSuggestion, error)
	ListTitleSuggestions(ctx context.Context, q domain.SuggestionQuery) ([]domain.RuleSuggestion, error)
	ApplyEventMappings(ctx context.Context, updates []domain.EventMappingUpdate, manuallyMapped bool) (int64, error)
	CurrentProjectID(ctx context.Context) (*int64, error)
	FindProjectIDByTitle(ctx context.Context, title string) (*int64, error)
	FindActivityIDByTitle(ctx context.Context, projectID int64, title string) (*int64, error)
}

type ReportsRepository interface {
	ListReportEvents(ctx context.Context, rangeKey string) ([]domain.Event, error)
}

type ProjectsRepository interface {
	ListActiveProjects(ctx context.Context) ([]domain.Project, error)
	ListAllProjects(ctx context.Context) ([]domain.Project, error)
	ActivateProject(ctx context.Context, projectID int64) error
	EndProject(ctx context.Context, projectID int64) error
	EndAllProjects(ctx context.Context) error
	CurrentProject(ctx context.Context) (string, *int64, error)
}

type SettingsRepository interface {
	Load(ctx context.Context) (domain.Settings, string, error)
	Save(ctx context.Context, cfg domain.Settings) (string, error)
}

type LifecyclePort interface {
	Install(ctx context.Context) error
	Uninstall(ctx context.Context) error
	Start(ctx context.Context) error
	Stop(ctx context.Context) error
	Status(ctx context.Context) domain.LifecycleStatus
}

type ReviewRepository interface {
	ListUnmappedDates(ctx context.Context, minDurationMS int64) ([]string, error)
	ListGroupedUnmappedEvents(ctx context.Context, date string, minDurationMS int64) ([]domain.GroupedEvent, error)
	MapEventsByGroup(ctx context.Context, date, appName, windowTitle string, projectID, activityID int64) (int64, error)
	DiscardEventsByGroup(ctx context.Context, date, appName, windowTitle string) (int64, error)
}

type TidsregGateway interface {
	Authenticate(ctx context.Context, username, password string) (string, error)
	ListCustomers(ctx context.Context, sessionCookie string, mode domain.TidsregMode) ([]domain.TidsregCustomer, error)
	ListProjects(ctx context.Context, sessionCookie string, customerID int64, mode domain.TidsregMode) ([]domain.TidsregProject, error)
	ListPhases(ctx context.Context, sessionCookie string, projectID int64, mode domain.TidsregMode) ([]domain.TidsregPhase, error)
	ListActivities(ctx context.Context, sessionCookie string, phaseID int64, mode domain.TidsregMode) ([]domain.TidsregActivity, error)
}

type TidsregImportRepository interface {
	UpsertImportedProject(ctx context.Context, in domain.ImportedProjectUpsert) (domain.ImportedProjectUpsertResult, error)
	SyncImportedActivities(ctx context.Context, projectID int64, activities []domain.ImportedActivityUpsert) (domain.ImportedActivitySyncResult, error)
}
