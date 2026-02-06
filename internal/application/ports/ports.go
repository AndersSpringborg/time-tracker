package ports

import (
	"context"

	"time-tracker/internal/domain"
)

type RulesRepository interface {
	ListRules(ctx context.Context) ([]domain.Rule, error)
	AddRule(ctx context.Context, in domain.RuleInput) (int64, error)
	DeleteRule(ctx context.Context, id int64) error
	AnalyzeSuggestions(ctx context.Context, q domain.SuggestionQuery) ([]domain.RuleSuggestion, error)
	AcceptSuggestion(ctx context.Context, in domain.ApplySuggestionInput) (domain.ApplySuggestionResult, error)
	ApplyRules(ctx context.Context, in domain.ApplyRulesInput) (domain.ApplyRulesResult, error)
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
	MapEventsByGroup(ctx context.Context, date, appName, windowTitle string, activityID, kindID int64) (int64, error)
	DiscardEventsByGroup(ctx context.Context, date, appName, windowTitle string) (int64, error)
}
