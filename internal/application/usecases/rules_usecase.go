package usecases

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"time-tracker/internal/application/contracts"
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

func (u *RulesUsecase) ListRules(ctx context.Context, _ contracts.RulesListRequest) (contracts.RulesListResponse, error) {
	rules, err := u.repo.ListRules(ctx)
	if err != nil {
		return contracts.RulesListResponse{}, err
	}
	return contracts.RulesListResponse{Rules: rules}, nil
}

func (u *RulesUsecase) AddRule(ctx context.Context, req contracts.RulesAddRequest) (contracts.RulesAddResponse, error) {
	in := domain.NormalizeRuleInput(req.Rule)
	if err := validateRuleInput(in); err != nil {
		return contracts.RulesAddResponse{}, err
	}
	id, err := u.repo.AddRule(ctx, in)
	if err != nil {
		return contracts.RulesAddResponse{}, err
	}
	return contracts.RulesAddResponse{RuleID: id}, nil
}

func (u *RulesUsecase) DeleteRule(ctx context.Context, req contracts.RulesDeleteRequest) (contracts.RulesDeleteResponse, error) {
	if err := u.repo.DeleteRule(ctx, req.RuleID); err != nil {
		return contracts.RulesDeleteResponse{}, err
	}
	return contracts.RulesDeleteResponse{}, nil
}

func (u *RulesUsecase) AddRuleToDraft(ctx context.Context, req contracts.RulesDraftAddRequest) (contracts.RulesDraftAddResponse, error) {
	in := domain.NormalizeRuleInput(req.Rule)
	if err := validateRuleInput(in); err != nil {
		return contracts.RulesDraftAddResponse{}, err
	}
	u.draftMu.Lock()
	defer u.draftMu.Unlock()
	if err := u.ensureDraftLocked(ctx); err != nil {
		return contracts.RulesDraftAddResponse{}, err
	}

	rule := ruleFromInput(u.draft.nextID, in)
	u.draft.nextID--
	u.draft.working = append(u.draft.working, rule)
	return contracts.RulesDraftAddResponse{}, nil
}

func (u *RulesUsecase) AddRuleToDraftFromForm(ctx context.Context, req contracts.RulesDraftAddFromFormRequest) (contracts.RulesDraftAddResponse, error) {
	in, err := u.resolveDraftRuleInput(ctx, req.Rule, req.TargetProjectName, req.TargetActivity)
	if err != nil {
		return contracts.RulesDraftAddResponse{}, err
	}
	return u.AddRuleToDraft(ctx, contracts.RulesDraftAddRequest{Rule: in})
}

func (u *RulesUsecase) AddRegexRuleFromGroupsToDraft(ctx context.Context, req contracts.RulesDraftAddFromGroupsRequest) (contracts.RulesDraftAddFromGroupsResponse, error) {
	appPattern, titlePattern, err := domain.BuildRegexRuleFromGroups(req.Groups)
	if err != nil {
		return contracts.RulesDraftAddFromGroupsResponse{}, err
	}
	in := req.Rule
	in.AppPattern = appPattern
	in.TitlePattern = titlePattern
	_, err = u.AddRuleToDraft(ctx, contracts.RulesDraftAddRequest{Rule: in})
	return contracts.RulesDraftAddFromGroupsResponse{}, err
}

func (u *RulesUsecase) AddRegexRuleFromGroupsToDraftFromForm(ctx context.Context, req contracts.RulesDraftAddFromGroupsFormRequest) (contracts.RulesDraftAddFromGroupsResponse, error) {
	in, err := u.resolveDraftRuleInput(ctx, req.Rule, req.TargetProjectName, req.TargetActivityName)
	if err != nil {
		return contracts.RulesDraftAddFromGroupsResponse{}, err
	}
	return u.AddRegexRuleFromGroupsToDraft(ctx, contracts.RulesDraftAddFromGroupsRequest{
		Groups: req.Groups,
		Rule:   in,
	})
}

func (u *RulesUsecase) DeleteRuleFromDraft(ctx context.Context, req contracts.RulesDraftDeleteRequest) (contracts.RulesDraftDeleteResponse, error) {
	u.draftMu.Lock()
	defer u.draftMu.Unlock()
	if err := u.ensureDraftLocked(ctx); err != nil {
		return contracts.RulesDraftDeleteResponse{}, err
	}

	next := make([]domain.Rule, 0, len(u.draft.working))
	for _, rule := range u.draft.working {
		if rule.ID == req.RuleID {
			continue
		}
		next = append(next, rule)
	}
	u.draft.working = next
	return contracts.RulesDraftDeleteResponse{}, nil
}

func (u *RulesUsecase) ReAddDefaultRulesToDraft(ctx context.Context, _ contracts.RulesDraftReAddDefaultsRequest) (contracts.RulesDraftReAddDefaultsResponse, error) {
	u.draftMu.Lock()
	defer u.draftMu.Unlock()
	if err := u.ensureDraftLocked(ctx); err != nil {
		return contracts.RulesDraftReAddDefaultsResponse{}, err
	}

	defaults := domain.DefaultRules()
	warnings := make([]string, 0)
	for _, def := range defaults {
		def = domain.NormalizeRuleInput(def)
		if def.ActionType == domain.RuleActionAssignProjectAndActivityByT {
			projectID, err := u.repo.FindProjectIDByTitle(ctx, def.ActionProjectTitle)
			if err != nil {
				return contracts.RulesDraftReAddDefaultsResponse{}, err
			}
			if projectID == nil {
				warnings = append(warnings, fmt.Sprintf("Skipped %q: project %q not found", def.RuleKey, def.ActionProjectTitle))
				continue
			}
			activityID, err := u.repo.FindActivityIDByTitle(ctx, *projectID, def.ActionActivityName)
			if err != nil {
				return contracts.RulesDraftReAddDefaultsResponse{}, err
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
	return contracts.RulesDraftReAddDefaultsResponse{Warnings: cloneStrings(warnings)}, nil
}

func (u *RulesUsecase) DraftPreview(ctx context.Context, _ contracts.RulesDraftPreviewRequest) (contracts.RulesDraftPreviewResponse, error) {
	u.draftMu.Lock()
	defer u.draftMu.Unlock()
	if err := u.ensureDraftLocked(ctx); err != nil {
		return contracts.RulesDraftPreviewResponse{}, err
	}
	return contracts.RulesDraftPreviewResponse{
		Preview: domain.BuildDraftPreview(u.draft.base, u.draft.working, cloneStrings(u.draft.warn)),
	}, nil
}

func (u *RulesUsecase) SaveDraft(ctx context.Context, _ contracts.RulesDraftSaveRequest) (contracts.RulesDraftSaveResponse, error) {
	u.draftMu.Lock()
	defer u.draftMu.Unlock()
	if err := u.ensureDraftLocked(ctx); err != nil {
		return contracts.RulesDraftSaveResponse{}, err
	}

	changes := buildRulesetChanges(u.draft.base, u.draft.working)
	result, err := u.repo.ApplyRulesetChanges(ctx, changes)
	if err != nil {
		return contracts.RulesDraftSaveResponse{}, err
	}
	u.draft = nil
	return contracts.RulesDraftSaveResponse{Result: result}, nil
}

func (u *RulesUsecase) DiscardDraft(_ context.Context, _ contracts.RulesDraftDiscardRequest) (contracts.RulesDraftDiscardResponse, error) {
	u.draftMu.Lock()
	defer u.draftMu.Unlock()
	u.draft = nil
	return contracts.RulesDraftDiscardResponse{}, nil
}

func (u *RulesUsecase) ListUnmappedDates(ctx context.Context, req contracts.RulesUnmappedDatesRequest) (contracts.RulesUnmappedDatesResponse, error) {
	dates, err := u.repo.ListUnmappedDates(ctx, req.MinDurationMS)
	if err != nil {
		return contracts.RulesUnmappedDatesResponse{}, err
	}
	return contracts.RulesUnmappedDatesResponse{Dates: dates}, nil
}

func (u *RulesUsecase) ListGroupedUnmappedEvents(ctx context.Context, req contracts.RulesUnmappedGroupsRequest) (contracts.RulesUnmappedGroupsResponse, error) {
	groups, err := u.repo.ListGroupedUnmappedEvents(ctx, req.Date, req.MinDurationMS)
	if err != nil {
		return contracts.RulesUnmappedGroupsResponse{}, err
	}
	return contracts.RulesUnmappedGroupsResponse{Groups: groups}, nil
}

func (u *RulesUsecase) ApplyRules(ctx context.Context, req contracts.RulesApplyRequest) (contracts.RulesApplyResponse, error) {
	in := req.Input
	rules, err := u.repo.ListRules(ctx)
	if err != nil {
		return contracts.RulesApplyResponse{}, err
	}
	events, err := u.repo.ListUnmappedEvents(ctx, in.Date, 0)
	if err != nil {
		return contracts.RulesApplyResponse{}, err
	}
	currentProjectID, err := u.repo.CurrentProjectID(ctx)
	if err != nil {
		return contracts.RulesApplyResponse{}, err
	}

	resolver := newRuleResolver(ctx, u.repo)
	updates, _, err := domain.MatchEventToRulesWithResolver(events, rules, currentProjectID, resolver)
	if err != nil {
		return contracts.RulesApplyResponse{}, err
	}
	res := domain.ApplyRulesResult{UnmappedEvents: int64(len(events)), MatchedEvents: int64(len(updates))}
	if in.DryRun || len(updates) == 0 {
		return contracts.RulesApplyResponse{Result: res}, nil
	}
	if _, err := u.repo.ApplyEventMappings(ctx, updates, false); err != nil {
		return contracts.RulesApplyResponse{}, err
	}
	return contracts.RulesApplyResponse{Result: res}, nil
}

func (u *RulesUsecase) ApplyRulesPreview(ctx context.Context, req contracts.RulesApplyPreviewRequest) (contracts.RulesApplyPreviewResponse, error) {
	// Get date string for grouping query
	date := ""
	if req.Date != nil {
		date = *req.Date
	} else {
		date = time.Now().Format("2006-01-02")
	}

	// Get grouped unmapped events
	groups, err := u.repo.ListGroupedUnmappedEvents(ctx, date, req.MinDurationMS)
	if err != nil {
		return contracts.RulesApplyPreviewResponse{}, err
	}

	// Get rules
	rules, err := u.repo.ListRules(ctx)
	if err != nil {
		return contracts.RulesApplyPreviewResponse{}, err
	}

	// Get current project ID
	currentProjectID, err := u.repo.CurrentProjectID(ctx)
	if err != nil {
		return contracts.RulesApplyPreviewResponse{}, err
	}

	// Match groups to rules
	resolver := newRuleResolver(ctx, u.repo)
	matches := domain.MatchGroupedEventsToRules(groups, rules, currentProjectID, resolver)

	// Calculate counts
	var matchedCount, unmappedCount int64
	var totalDuration, matchedDuration int64
	for _, m := range matches {
		totalDuration += m.TotalDurationMS
		if m.MatchedRule != nil {
			matchedCount++
			matchedDuration += m.TotalDurationMS
		} else {
			unmappedCount++
		}
	}

	// Get assignment targets for the inline add-rule form
	targetsRes, err := u.ListAssignmentTargets(ctx, contracts.RulesAssignmentTargetsRequest{})
	if err != nil {
		return contracts.RulesApplyPreviewResponse{}, err
	}

	return contracts.RulesApplyPreviewResponse{
		Matches:           matches,
		MatchedCount:      matchedCount,
		UnmappedCount:     unmappedCount,
		TotalDurationMS:   totalDuration,
		MatchedDurationMS: matchedDuration,
		AssignmentTargets: targetsRes.Targets,
		Date:              date,
		MinDurationMS:     req.MinDurationMS,
	}, nil
}

func (u *RulesUsecase) ListAssignmentTargets(ctx context.Context, _ contracts.RulesAssignmentTargetsRequest) (contracts.RulesAssignmentTargetsResponse, error) {
	projects, err := u.repo.ListAllProjects(ctx)
	if err != nil {
		return contracts.RulesAssignmentTargetsResponse{}, err
	}
	targets := make([]domain.RuleAssignmentTarget, 0)
	for _, project := range projects {
		activities, err := u.repo.ListActivitiesByProject(ctx, project.ProjectID)
		if err != nil {
			return contracts.RulesAssignmentTargetsResponse{}, err
		}
		for _, activity := range activities {
			targets = append(targets, domain.RuleAssignmentTarget{
				ProjectTitle:  project.Title,
				ActivityTitle: activity.Title,
			})
		}
	}
	return contracts.RulesAssignmentTargetsResponse{Targets: targets}, nil
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

func (u *RulesUsecase) resolveDraftRuleInput(ctx context.Context, in domain.RuleInput, targetProjectTitle, targetActivityName string) (domain.RuleInput, error) {
	in = domain.NormalizeRuleInput(in)
	if in.ActionType != domain.RuleActionAssignExplicit {
		return in, nil
	}
	if in.ProjectID != nil && in.ActivityID != nil {
		return in, nil
	}

	projectTitle := strings.TrimSpace(targetProjectTitle)
	activityName := strings.TrimSpace(targetActivityName)
	if projectTitle == "" || activityName == "" {
		return domain.RuleInput{}, fmt.Errorf("select a project and activity target")
	}
	projectID, err := u.repo.FindProjectIDByTitle(ctx, projectTitle)
	if err != nil {
		return domain.RuleInput{}, err
	}
	if projectID == nil {
		return domain.RuleInput{}, fmt.Errorf("project %q not found", projectTitle)
	}
	activityID, err := u.repo.FindActivityIDByTitle(ctx, *projectID, activityName)
	if err != nil {
		return domain.RuleInput{}, err
	}
	if activityID == nil {
		return domain.RuleInput{}, fmt.Errorf("activity %q not found in project %q", activityName, projectTitle)
	}
	in.ProjectID = cloneInt64Ptr(projectID)
	in.ActivityID = cloneInt64Ptr(activityID)
	return in, nil
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
