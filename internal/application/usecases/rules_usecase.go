package usecases

import (
	"context"
	"fmt"
	"strings"
	"sync"

	"time-tracker/internal/application/ports"
	"time-tracker/internal/domain"
)

type RulesUsecase struct {
	repo ports.RulesRepository

	draftMu sync.Mutex
	draft   *rulesDraft
}

type rulesDraft struct {
	base    []domain.Rule
	working []domain.Rule
	nextID  int64
	warn    []string
}

func NewRulesUsecase(repo ports.RulesRepository) *RulesUsecase {
	return &RulesUsecase{repo: repo}
}

func (u *RulesUsecase) ListRules(ctx context.Context) ([]domain.Rule, error) {
	return u.repo.ListRules(ctx)
}

func (u *RulesUsecase) AddRule(ctx context.Context, in domain.RuleInput) (int64, error) {
	in = domain.NormalizeRuleInput(in)
	if err := validateRuleInput(in); err != nil {
		return 0, err
	}
	return u.repo.AddRule(ctx, in)
}

func (u *RulesUsecase) DeleteRule(ctx context.Context, id int64) error {
	return u.repo.DeleteRule(ctx, id)
}

func (u *RulesUsecase) AddRuleToDraft(ctx context.Context, in domain.RuleInput) error {
	in = domain.NormalizeRuleInput(in)
	if err := validateRuleInput(in); err != nil {
		return err
	}
	u.draftMu.Lock()
	defer u.draftMu.Unlock()
	if err := u.ensureDraftLocked(ctx); err != nil {
		return err
	}

	rule := ruleFromInput(u.draft.nextID, in)
	u.draft.nextID--
	u.draft.working = append(u.draft.working, rule)
	return nil
}

func (u *RulesUsecase) AddRegexRuleFromGroupsToDraft(ctx context.Context, groups []domain.GroupedEvent, in domain.RuleInput) error {
	appPattern, titlePattern, err := domain.BuildRegexRuleFromGroups(groups)
	if err != nil {
		return err
	}
	in.AppPattern = appPattern
	in.TitlePattern = titlePattern
	return u.AddRuleToDraft(ctx, in)
}

func (u *RulesUsecase) DeleteRuleFromDraft(ctx context.Context, id int64) error {
	u.draftMu.Lock()
	defer u.draftMu.Unlock()
	if err := u.ensureDraftLocked(ctx); err != nil {
		return err
	}

	next := make([]domain.Rule, 0, len(u.draft.working))
	for _, rule := range u.draft.working {
		if rule.ID == id {
			continue
		}
		next = append(next, rule)
	}
	u.draft.working = next
	return nil
}

func (u *RulesUsecase) ReAddDefaultRulesToDraft(ctx context.Context) ([]string, error) {
	u.draftMu.Lock()
	defer u.draftMu.Unlock()
	if err := u.ensureDraftLocked(ctx); err != nil {
		return nil, err
	}

	defaults := domain.DefaultBrowserRules()
	warnings := make([]string, 0)
	for _, def := range defaults {
		def = domain.NormalizeRuleInput(def)
		if def.ActionType == domain.RuleActionAssignProjectAndActivityByT {
			projectID, err := u.repo.FindProjectIDByTitle(ctx, def.ActionProjectTitle)
			if err != nil {
				return nil, err
			}
			if projectID == nil {
				warnings = append(warnings, fmt.Sprintf("Skipped %q: project %q not found", def.RuleKey, def.ActionProjectTitle))
				continue
			}
			activityID, err := u.repo.FindActivityIDByTitle(ctx, *projectID, def.ActionActivityName)
			if err != nil {
				return nil, err
			}
			if activityID == nil {
				warnings = append(warnings, fmt.Sprintf("Skipped %q: activity %q not found in project %q", def.RuleKey, def.ActionActivityName, def.ActionProjectTitle))
				continue
			}
		}

		found := false
		for i := range u.draft.working {
			if u.draft.working[i].RuleKey == def.RuleKey && def.RuleKey != "" {
				existing := u.draft.working[i]
				u.draft.working[i] = ruleFromInput(existing.ID, def)
				found = true
				break
			}
		}
		if found {
			continue
		}
		for _, base := range u.draft.base {
			if base.RuleKey == def.RuleKey && def.RuleKey != "" {
				u.draft.working = append(u.draft.working, ruleFromInput(base.ID, def))
				found = true
				break
			}
		}
		if found {
			continue
		}
		u.draft.working = append(u.draft.working, ruleFromInput(u.draft.nextID, def))
		u.draft.nextID--
	}

	u.draft.warn = append(u.draft.warn[:0], warnings...)
	return cloneStrings(warnings), nil
}

func (u *RulesUsecase) DraftPreview(ctx context.Context) (domain.RuleDraftPreview, error) {
	u.draftMu.Lock()
	defer u.draftMu.Unlock()
	if err := u.ensureDraftLocked(ctx); err != nil {
		return domain.RuleDraftPreview{}, err
	}
	return domain.BuildDraftPreview(u.draft.base, u.draft.working, cloneStrings(u.draft.warn)), nil
}

func (u *RulesUsecase) SaveDraft(ctx context.Context) (domain.RulesetApplyResult, error) {
	u.draftMu.Lock()
	defer u.draftMu.Unlock()
	if err := u.ensureDraftLocked(ctx); err != nil {
		return domain.RulesetApplyResult{}, err
	}

	changes := buildRulesetChanges(u.draft.base, u.draft.working)
	result, err := u.repo.ApplyRulesetChanges(ctx, changes)
	if err != nil {
		return result, err
	}
	u.draft = nil
	return result, nil
}

func (u *RulesUsecase) DiscardDraft() {
	u.draftMu.Lock()
	defer u.draftMu.Unlock()
	u.draft = nil
}

func (u *RulesUsecase) ListUnmappedDates(ctx context.Context, minDurationMS int64) ([]string, error) {
	return u.repo.ListUnmappedDates(ctx, minDurationMS)
}

func (u *RulesUsecase) ListGroupedUnmappedEvents(ctx context.Context, date string, minDurationMS int64) ([]domain.GroupedEvent, error) {
	return u.repo.ListGroupedUnmappedEvents(ctx, date, minDurationMS)
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
	titlePattern := domain.BuildTitlePattern("")
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
		ActionType:   domain.RuleActionAssignExplicit,
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

	resolver := newRuleResolver(ctx, u.repo)
	updates, _, err := domain.MatchEventToRulesWithResolver(events, rules, currentProjectID, resolver)
	if err != nil {
		return domain.ApplyRulesResult{}, err
	}
	res := domain.ApplyRulesResult{UnmappedEvents: int64(len(events)), MatchedEvents: int64(len(updates))}
	if in.DryRun || len(updates) == 0 {
		return res, nil
	}
	if _, err := u.repo.ApplyEventMappings(ctx, updates, false); err != nil {
		return res, err
	}
	return res, nil
}

type ruleResolver struct {
	ctx  context.Context
	repo ports.RulesRepository

	projectByTitle map[string]*int64
	activityByKey  map[string]*int64
}

func newRuleResolver(ctx context.Context, repo ports.RulesRepository) *ruleResolver {
	return &ruleResolver{
		ctx:            ctx,
		repo:           repo,
		projectByTitle: map[string]*int64{},
		activityByKey:  map[string]*int64{},
	}
}

func (r *ruleResolver) FindProjectIDByTitle(title string) (*int64, error) {
	key := strings.ToLower(strings.TrimSpace(title))
	if cached, ok := r.projectByTitle[key]; ok {
		return cloneInt64Ptr(cached), nil
	}
	value, err := r.repo.FindProjectIDByTitle(r.ctx, title)
	if err != nil {
		return nil, err
	}
	r.projectByTitle[key] = cloneInt64Ptr(value)
	return cloneInt64Ptr(value), nil
}

func (r *ruleResolver) FindActivityIDByTitle(projectID int64, title string) (*int64, error) {
	key := fmt.Sprintf("%d::%s", projectID, strings.ToLower(strings.TrimSpace(title)))
	if cached, ok := r.activityByKey[key]; ok {
		return cloneInt64Ptr(cached), nil
	}
	value, err := r.repo.FindActivityIDByTitle(r.ctx, projectID, title)
	if err != nil {
		return nil, err
	}
	r.activityByKey[key] = cloneInt64Ptr(value)
	return cloneInt64Ptr(value), nil
}

func buildRulesetChanges(baseRules []domain.Rule, workingRules []domain.Rule) domain.RulesetChanges {
	baseByID := map[int64]domain.Rule{}
	for _, rule := range baseRules {
		baseByID[rule.ID] = rule
	}
	workingByID := map[int64]domain.Rule{}
	changes := domain.RulesetChanges{
		Adds:    make([]domain.RuleInput, 0),
		Updates: make([]domain.RuleUpdate, 0),
		Deletes: make([]int64, 0),
	}

	for _, rule := range workingRules {
		if rule.ID > 0 {
			workingByID[rule.ID] = rule
		}
		input := ruleToInput(rule)
		if rule.ID < 0 {
			changes.Adds = append(changes.Adds, input)
			continue
		}
		base, ok := baseByID[rule.ID]
		if !ok {
			changes.Adds = append(changes.Adds, input)
			continue
		}
		if !rule.Equals(base) {
			changes.Updates = append(changes.Updates, domain.RuleUpdate{
				ID:   rule.ID,
				Rule: input,
			})
		}
	}
	for _, base := range baseRules {
		if _, ok := workingByID[base.ID]; ok {
			continue
		}
		changes.Deletes = append(changes.Deletes, base.ID)
	}
	return changes
}

func ruleToInput(rule domain.Rule) domain.RuleInput {
	return domain.NormalizeRuleInput(domain.RuleInput{
		RuleKey:            rule.RuleKey,
		Source:             rule.Source,
		Priority:           rule.Priority,
		AppPattern:         rule.AppPattern,
		TitlePattern:       rule.TitlePattern,
		ProjectID:          cloneInt64Ptr(rule.ProjectID),
		ActivityID:         cloneInt64Ptr(rule.ActivityID),
		FollowPrevious:     rule.FollowPrevious,
		ActionType:         rule.ActionType,
		ActionProjectTitle: rule.ActionProjectTitle,
		ActionActivityName: rule.ActionActivityName,
	})
}

func ruleFromInput(id int64, in domain.RuleInput) domain.Rule {
	in = domain.NormalizeRuleInput(in)
	rule := domain.Rule{
		ID:                 id,
		RuleKey:            in.RuleKey,
		Source:             in.Source,
		Priority:           in.Priority,
		AppPattern:         in.AppPattern,
		TitlePattern:       in.TitlePattern,
		ProjectID:          cloneInt64Ptr(in.ProjectID),
		ActivityID:         cloneInt64Ptr(in.ActivityID),
		FollowPrevious:     in.FollowPrevious,
		ActionType:         in.ActionType,
		ActionProjectTitle: in.ActionProjectTitle,
		ActionActivityName: in.ActionActivityName,
	}
	rule.DisplayTarget = rule.DisplayTargetText()
	return rule
}

func (u *RulesUsecase) ensureDraftLocked(ctx context.Context) error {
	if u.draft != nil {
		return nil
	}
	rules, err := u.repo.ListRules(ctx)
	if err != nil {
		return err
	}
	u.draft = &rulesDraft{
		base:    cloneRules(rules),
		working: cloneRules(rules),
		nextID:  -1,
		warn:    nil,
	}
	return nil
}

func cloneRules(items []domain.Rule) []domain.Rule {
	out := make([]domain.Rule, 0, len(items))
	for _, item := range items {
		copyRule := item
		copyRule.ProjectID = cloneInt64Ptr(item.ProjectID)
		copyRule.ActivityID = cloneInt64Ptr(item.ActivityID)
		out = append(out, copyRule)
	}
	return out
}

func cloneInt64Ptr(value *int64) *int64 {
	if value == nil {
		return nil
	}
	copyValue := *value
	return &copyValue
}

func cloneStrings(values []string) []string {
	out := make([]string, len(values))
	copy(out, values)
	return out
}

func validateRuleInput(in domain.RuleInput) error {
	switch in.ActionType {
	case domain.RuleActionFollowCurrentContext:
		return nil
	case domain.RuleActionAssignActivityCurrent:
		if strings.TrimSpace(in.ActionActivityName) == "" {
			return fmt.Errorf("action_activity_name is required for assign_activity_in_current_project")
		}
		return nil
	case domain.RuleActionAssignProjectAndActivityByT:
		if strings.TrimSpace(in.ActionProjectTitle) == "" {
			return fmt.Errorf("action_project_title is required for assign_project_activity_by_title")
		}
		if strings.TrimSpace(in.ActionActivityName) == "" {
			return fmt.Errorf("action_activity_name is required for assign_project_activity_by_title")
		}
		return nil
	default:
		if in.ProjectID == nil || in.ActivityID == nil {
			return fmt.Errorf("project_id and activity_id are required unless dynamic action is enabled")
		}
		return nil
	}
}
