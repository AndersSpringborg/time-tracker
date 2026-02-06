package usecases

import (
	"context"

	"time-tracker/internal/application/ports"
	"time-tracker/internal/domain"
)

type ReviewUsecase struct{ repo ports.ReviewRepository }

func NewReviewUsecase(repo ports.ReviewRepository) *ReviewUsecase { return &ReviewUsecase{repo: repo} }

func (u *ReviewUsecase) Dates(ctx context.Context, minDurationMS int64) ([]string, error) {
	return u.repo.ListUnmappedDates(ctx, minDurationMS)
}

func (u *ReviewUsecase) Groups(ctx context.Context, date string, minDurationMS int64) ([]domain.GroupedEvent, error) {
	return u.repo.ListGroupedUnmappedEvents(ctx, date, minDurationMS)
}

func (u *ReviewUsecase) MapGroup(ctx context.Context, date, app, title string, activityID, kindID int64) (int64, error) {
	return u.repo.MapEventsByGroup(ctx, date, app, title, activityID, kindID)
}

func (u *ReviewUsecase) DiscardGroup(ctx context.Context, date, app, title string) (int64, error) {
	return u.repo.DiscardEventsByGroup(ctx, date, app, title)
}
