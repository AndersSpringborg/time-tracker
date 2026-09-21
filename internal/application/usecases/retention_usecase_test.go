package usecases

import (
	"context"
	"errors"
	"testing"

	"time-tracker/internal/domain"
)

// fakeRetentionRepo is an in-memory stand-in for stored detail: summarising a
// day removes its bytes, the way the real transaction does.
type fakeRetentionRepo struct {
	days       []domain.RetentionDay
	bytes      int64
	summarized []string
	failOn     string
}

func (f *fakeRetentionRepo) DetailBytes(context.Context) (int64, error) { return f.bytes, nil }

func (f *fakeRetentionRepo) RetentionDays(context.Context) ([]domain.RetentionDay, error) {
	return f.days, nil
}

func (f *fakeRetentionRepo) SummarizeDay(_ context.Context, day string) (domain.DaySummary, error) {
	if day == f.failOn {
		return domain.DaySummary{}, errors.New("disk failure")
	}
	for _, candidate := range f.days {
		if candidate.Day == day {
			f.bytes -= candidate.EstimatedBytes
			f.summarized = append(f.summarized, day)
			return domain.DaySummary{Day: day, EventCount: candidate.Events, TotalMS: candidate.TotalMS}, nil
		}
	}
	return domain.DaySummary{}, errors.New("unknown day")
}

func retentionFixture() *fakeRetentionRepo {
	return &fakeRetentionRepo{
		bytes: 1000,
		days: []domain.RetentionDay{
			{Day: "2026-01-01", Events: 100, EstimatedBytes: 300, UnmappedEvents: 90},
			{Day: "2026-01-02", Events: 100, EstimatedBytes: 300},
			{Day: "2026-01-03", Events: 100, EstimatedBytes: 300},
		},
	}
}

func TestRetentionDoesNothingBelowTheCap(t *testing.T) {
	repo := retentionFixture()
	usecase := NewRetentionUsecase(repo).WithCap(2000)

	plan, err := usecase.Plan(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Days) != 0 || plan.OverCapBy() != 0 {
		t.Fatalf("plan should be empty below the cap: %+v", plan)
	}
	if _, err := usecase.Apply(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(repo.summarized) != 0 {
		t.Fatalf("nothing should have been summarised, got %v", repo.summarized)
	}
}

func TestRetentionSummarizesOldestDaysUntilUnderTheCap(t *testing.T) {
	repo := retentionFixture()
	usecase := NewRetentionUsecase(repo).WithCap(500)

	plan, err := usecase.Plan(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Days) != 2 || plan.Days[0].Day != "2026-01-01" || plan.Days[1].Day != "2026-01-02" {
		t.Fatalf("expected the two oldest days, got %+v", plan.Days)
	}
	if plan.Events != 200 || plan.UnmappedEvents != 90 {
		t.Fatalf("plan must report what is affected: %+v", plan)
	}

	outcome, err := usecase.Apply(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(outcome.Summarized) != 2 {
		t.Fatalf("summarised %+v", outcome.Summarized)
	}
	if repo.bytes > 500 {
		t.Fatalf("still above the cap: %d bytes", repo.bytes)
	}
	// The newest day keeps its detail.
	for _, day := range repo.summarized {
		if day == "2026-01-03" {
			t.Fatal("the newest day must keep its detail")
		}
	}
}

func TestRetentionPlanReportsWithoutChangingAnything(t *testing.T) {
	repo := retentionFixture()
	usecase := NewRetentionUsecase(repo).WithCap(500)

	if _, err := usecase.Plan(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(repo.summarized) != 0 || repo.bytes != 1000 {
		t.Fatal("planning must not summarise or delete anything")
	}
}

func TestRetentionKeepsCompletedDaysWhenOneFails(t *testing.T) {
	repo := retentionFixture()
	repo.failOn = "2026-01-02"
	usecase := NewRetentionUsecase(repo).WithCap(500)

	outcome, err := usecase.Apply(context.Background())
	if err == nil {
		t.Fatal("expected the failure to be reported")
	}
	if len(outcome.Summarized) != 1 || outcome.Summarized[0].Day != "2026-01-01" {
		t.Fatalf("the day that succeeded must be reported as done: %+v", outcome.Summarized)
	}
	if len(repo.summarized) != 1 {
		t.Fatalf("a failure must not roll back an already committed day: %v", repo.summarized)
	}
}
