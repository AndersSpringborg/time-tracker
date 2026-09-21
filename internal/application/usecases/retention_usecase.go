package usecases

import (
	"context"
	"fmt"

	"time-tracker/internal/application/ports"
	"time-tracker/internal/domain"
)

// RetentionUsecase keeps stored detail under a size cap. It summarises the
// oldest days first, so recent history — the part that is reviewed, corrected
// and shown on timelines — keeps its detail longest.
type RetentionUsecase struct {
	repo     ports.RetentionRepository
	capBytes int64
}

func NewRetentionUsecase(repo ports.RetentionRepository) *RetentionUsecase {
	return &RetentionUsecase{repo: repo, capBytes: domain.RetentionCapBytes}
}

// WithCap returns a use case bound to a different cap, used by tests and by an
// explicit operator override.
func (u *RetentionUsecase) WithCap(capBytes int64) *RetentionUsecase {
	return &RetentionUsecase{repo: u.repo, capBytes: capBytes}
}

// Plan reports what would be summarised, without changing anything.
func (u *RetentionUsecase) Plan(ctx context.Context) (domain.RetentionPlan, error) {
	dataBytes, err := u.repo.DetailBytes(ctx)
	if err != nil {
		return domain.RetentionPlan{}, err
	}
	plan := domain.RetentionPlan{DataBytes: dataBytes, CapBytes: u.capBytes}
	if plan.OverCapBy() == 0 {
		return plan, nil
	}
	days, err := u.repo.RetentionDays(ctx)
	if err != nil {
		return plan, err
	}
	remaining := dataBytes
	for _, day := range days {
		if remaining <= u.capBytes {
			break
		}
		plan.Days = append(plan.Days, day)
		plan.Events += day.Events
		plan.UnmappedEvents += day.UnmappedEvents
		plan.ReclaimedBytes += day.EstimatedBytes
		remaining -= day.EstimatedBytes
	}
	return plan, nil
}

// Apply summarises the planned days. Days below the cap are left untouched, so
// running it when there is nothing to do is harmless.
func (u *RetentionUsecase) Apply(ctx context.Context) (domain.RetentionOutcome, error) {
	plan, err := u.Plan(ctx)
	if err != nil {
		return domain.RetentionOutcome{}, err
	}
	outcome := domain.RetentionOutcome{Plan: plan}
	for _, day := range plan.Days {
		summary, err := u.repo.SummarizeDay(ctx, day.Day)
		if err != nil {
			// Each day commits on its own, so the days already summarised stay
			// summarised and the run can be retried from here.
			return outcome, fmt.Errorf("summarize %s: %w", day.Day, err)
		}
		outcome.Summarized = append(outcome.Summarized, summary)
	}
	return outcome, nil
}
