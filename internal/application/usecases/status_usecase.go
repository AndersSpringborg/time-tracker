package usecases

import (
	"context"

	"time-tracker/internal/application/ports"
	"time-tracker/internal/domain"
)

// StatusUsecase answers the worker's menubar status question: how much review
// work is outstanding, and what the focused window would map to. It is
// read-only, so the menu can ask as often as it likes.
type StatusUsecase struct{ repo ports.StatusRepository }

func NewStatusUsecase(repo ports.StatusRepository) *StatusUsecase {
	return &StatusUsecase{repo: repo}
}

func (u *StatusUsecase) Status(ctx context.Context, window domain.WindowSnapshot) (domain.WorkerStatus, error) {
	unmatched, err := u.repo.UnmappedEventCount(ctx)
	if err != nil {
		return domain.WorkerStatus{}, err
	}
	status := domain.WorkerStatus{UnmatchedCount: unmatched}
	if window.AppName == "" && window.WindowTitle == "" {
		return status, nil
	}

	rules, err := u.repo.ListRules(ctx)
	if err != nil {
		return domain.WorkerStatus{}, err
	}
	currentProjectID, err := u.repo.CurrentProjectID(ctx)
	if err != nil {
		return domain.WorkerStatus{}, err
	}

	// One event through the same matcher the CLI uses, so the menu cannot
	// disagree with what `rules apply-rules` would decide. Rules that follow
	// the previous context have no history to follow here and stay unmatched,
	// which is honest: the menu does not know what came before.
	event := domain.Event{AppName: window.AppName, WindowTitle: window.WindowTitle}
	updates := domain.MatchEventToRules([]domain.Event{event}, rules, currentProjectID)
	if len(updates) == 0 {
		return status, nil
	}
	status.Matched = true

	match := updates[0]
	projects, err := u.repo.ListAllProjects(ctx)
	if err != nil {
		return domain.WorkerStatus{}, err
	}
	for _, project := range projects {
		if project.ProjectID == match.ProjectID {
			status.Project = project.Title
			break
		}
	}
	activities, err := u.repo.ListAllActivities(ctx)
	if err != nil {
		return domain.WorkerStatus{}, err
	}
	for _, activity := range activities {
		if activity.ActivityID == match.ActivityID {
			status.Activity = activity.Title
			break
		}
	}
	return status, nil
}
