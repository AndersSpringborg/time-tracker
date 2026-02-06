package usecases

import (
	"context"
	"sort"

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
	if in.Priority == 0 {
		in.Priority = 100
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
	items, err := u.repo.AnalyzeSuggestions(ctx, q)
	if err != nil {
		return nil, err
	}
	sort.Slice(items, func(i, j int) bool {
		if items[i].ImpactDurationMS == items[j].ImpactDurationMS {
			return items[i].Confidence > items[j].Confidence
		}
		return items[i].ImpactDurationMS > items[j].ImpactDurationMS
	})
	if len(items) > q.Limit {
		items = items[:q.Limit]
	}
	return items, nil
}

func (u *RulesUsecase) AcceptSuggestion(ctx context.Context, in domain.ApplySuggestionInput) (domain.ApplySuggestionResult, error) {
	return u.repo.AcceptSuggestion(ctx, in)
}

func (u *RulesUsecase) AutoApplySuggestions(ctx context.Context, in domain.AutoApplySuggestionsInput) (domain.AutoApplySuggestionsResult, error) {
	if in.Limit <= 0 {
		in.Limit = 100
	}
	if in.MinConfidence <= 0 {
		in.MinConfidence = 85
	}
	suggestions, err := u.repo.AnalyzeSuggestions(ctx, domain.SuggestionQuery{
		Date:          in.Date,
		MinDurationMS: in.MinDurationMS,
		Limit:         in.Limit,
	})
	if err != nil {
		return domain.AutoApplySuggestionsResult{}, err
	}

	res := domain.AutoApplySuggestionsResult{Analyzed: len(suggestions)}
	for _, s := range suggestions {
		if s.Confidence < in.MinConfidence {
			continue
		}
		applyRes, err := u.repo.AcceptSuggestion(ctx, domain.ApplySuggestionInput{
			Suggestion: s,
			ApplyNow:   in.ApplyNow,
			Date:       in.Date,
		})
		if err != nil {
			return res, err
		}
		if applyRes.RuleCreated {
			res.Accepted++
		}
		res.MappedEvents += applyRes.MappedEvents
	}
	return res, nil
}

func (u *RulesUsecase) ApplyRules(ctx context.Context, in domain.ApplyRulesInput) (domain.ApplyRulesResult, error) {
	return u.repo.ApplyRules(ctx, in)
}
