package usecases

import (
	"context"

	"time-tracker/internal/application/contracts"
	"time-tracker/internal/application/ports"
)

type ReviewUsecase struct{ repo ports.ReviewRepository }

func NewReviewUsecase(repo ports.ReviewRepository) *ReviewUsecase { return &ReviewUsecase{repo: repo} }

func (u *ReviewUsecase) Dates(ctx context.Context, req contracts.ReviewDatesRequest) (contracts.ReviewDatesResponse, error) {
	dates, err := u.repo.ListUnmappedDates(ctx, req.MinDurationMS)
	if err != nil {
		return contracts.ReviewDatesResponse{}, err
	}
	return contracts.ReviewDatesResponse{Dates: dates}, nil
}

func (u *ReviewUsecase) Groups(ctx context.Context, req contracts.ReviewGroupsRequest) (contracts.ReviewGroupsResponse, error) {
	groups, err := u.repo.ListGroupedUnmappedEvents(ctx, req.Date, req.MinDurationMS)
	if err != nil {
		return contracts.ReviewGroupsResponse{}, err
	}
	return contracts.ReviewGroupsResponse{Groups: groups}, nil
}

func (u *ReviewUsecase) MapGroup(ctx context.Context, req contracts.ReviewMapGroupRequest) (contracts.ReviewMapGroupResponse, error) {
	mapped, err := u.repo.MapEventsByGroup(ctx, req.Date, req.AppName, req.WindowTitle, req.ProjectID, req.ActivityID)
	if err != nil {
		return contracts.ReviewMapGroupResponse{}, err
	}
	return contracts.ReviewMapGroupResponse{Mapped: mapped}, nil
}

func (u *ReviewUsecase) DiscardGroup(ctx context.Context, req contracts.ReviewDiscardGroupRequest) (contracts.ReviewDiscardGroupResponse, error) {
	discarded, err := u.repo.DiscardEventsByGroup(ctx, req.Date, req.AppName, req.WindowTitle)
	if err != nil {
		return contracts.ReviewDiscardGroupResponse{}, err
	}
	return contracts.ReviewDiscardGroupResponse{Discarded: discarded}, nil
}
