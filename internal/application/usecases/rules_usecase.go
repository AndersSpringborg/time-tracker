package usecases

import (
	"context"
	"fmt"
	"strings"

	"time-tracker/internal/application/ports"
	"time-tracker/internal/domain"
)

type RulesUsecase struct {
	repo ports.RulesRepository
}

func NewRulesUsecase(repo ports.RulesRepository) *RulesUsecase {
	return &RulesUsecase{repo: repo}
}

func (u *RulesUsecase) ListRules(ctx context.Context) ([]domain.Rule, error) {
	return u.repo.ListRules(ctx)
}

func (u *RulesUsecase) AddRule(ctx context.Context, in domain.RuleInput) (int64, error) {
	in = domain.NormalizeRuleInput(in)
	if !in.FollowPrevious && (in.ProjectID == nil || in.ActivityID == nil) {
		return 0, fmt.Errorf("project_id and activity_id are required unless follow_previous is enabled")
	}
	return u.repo.AddRule(ctx, in)
}

func (u *RulesUsecase) DeleteRule(ctx context.Context, id int64) error {
	return u.repo.DeleteRule(ctx, id)
}

func (u *RulesUsecase) AnalyzeSuggestions(ctx context.Context, q domain.SuggestionQuery) ([]domain.RuleSuggestion, error) {
	if q.Limit <= 0 {
		q.Limit = 50
	}
	if q.MinDurationMS <= 0 {
		q.MinDurationMS = 2000
	}

	app, err := u.repo.ListAppSuggestions(ctx, q)
	if err != nil {
		return nil, err
	}
	title, err := u.repo.ListTitleSuggestions(ctx, q)
	if err != nil {
		return nil, err
	}
	all := append(app, title...)
	return domain.RankSuggestions(all, q.Limit), nil
}

func (u *RulesUsecase) AcceptSuggestion(ctx context.Context, in domain.ApplySuggestionInput) (domain.ApplySuggestionResult, error) {
	if in.Suggestion.ProjectID <= 0 || in.Suggestion.ActivityID <= 0 {
		return domain.ApplySuggestionResult{}, fmt.Errorf("project_id and activity_id are required")
	}
	titlePattern := "*"
	if in.Suggestion.TitlePattern != nil && strings.TrimSpace(*in.Suggestion.TitlePattern) != "" {
		titlePattern = *in.Suggestion.TitlePattern
	}
	projectID := in.Suggestion.ProjectID
	activityID := in.Suggestion.ActivityID
	_, err := u.repo.AddRule(ctx, domain.NormalizeRuleInput(domain.RuleInput{
		Priority:     100,
		AppPattern:   in.Suggestion.AppPattern,
		TitlePattern: titlePattern,
		ProjectID:    &projectID,
		ActivityID:   &activityID,
	}))
	if err != nil {
		return domain.ApplySuggestionResult{}, err
	}

	result := domain.ApplySuggestionResult{RuleCreated: true}
	if !in.ApplyNow {
		return result, nil
	}
	events, err := u.repo.ListUnmappedEvents(ctx, in.Date, 0)
	if err != nil {
		return result, err
	}
	updates := domain.MatchSuggestionToEvents(events, in.Suggestion)
	count, err := u.repo.ApplyEventMappings(ctx, updates, true)
	if err != nil {
		return result, err
	}
	result.MappedEvents = count
	return result, nil
}

func (u *RulesUsecase) AutoApplySuggestions(ctx context.Context, in domain.AutoApplySuggestionsInput) (domain.AutoApplySuggestionsResult, error) {
	if in.Limit <= 0 {
		in.Limit = 100
	}
	if in.MinConfidence <= 0 {
		in.MinConfidence = 85
	}
	q := domain.SuggestionQuery{Date: in.Date, MinDurationMS: in.MinDurationMS, Limit: in.Limit}
	suggestions, err := u.AnalyzeSuggestions(ctx, q)
	if err != nil {
		return domain.AutoApplySuggestionsResult{}, err
	}
	suggestions = domain.FilterSuggestionsMinConfidence(suggestions, in.MinConfidence)

	out := domain.AutoApplySuggestionsResult{Analyzed: len(suggestions)}
	for _, suggestion := range suggestions {
		res, err := u.AcceptSuggestion(ctx, domain.ApplySuggestionInput{
			Suggestion: suggestion,
			ApplyNow:   in.ApplyNow,
			Date:       in.Date,
		})
		if err != nil {
			return out, err
		}
		if res.RuleCreated {
			out.Accepted++
		}
		out.MappedEvents += res.MappedEvents
	}
	return out, nil
}

func (u *RulesUsecase) ApplyRules(ctx context.Context, in domain.ApplyRulesInput) (domain.ApplyRulesResult, error) {
	rules, err := u.repo.ListRules(ctx)
	if err != nil {
		return domain.ApplyRulesResult{}, err
	}
	events, err := u.repo.ListUnmappedEvents(ctx, in.Date, 0)
	if err != nil {
		return domain.ApplyRulesResult{}, err
	}
	currentProjectID, err := u.repo.CurrentProjectID(ctx)
	if err != nil {
		return domain.ApplyRulesResult{}, err
	}
	updates := domain.MatchEventToRules(events, rules, currentProjectID)
	res := domain.ApplyRulesResult{UnmappedEvents: int64(len(events)), MatchedEvents: int64(len(updates))}
	if in.DryRun || len(updates) == 0 {
		return res, nil
	}
	if _, err := u.repo.ApplyEventMappings(ctx, updates, false); err != nil {
		return res, err
	}
	return res, nil
}
