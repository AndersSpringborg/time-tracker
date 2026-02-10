package api

import (
	"bytes"
	"context"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	tidsregmodel "time-tracker/internal/application/integrations/tidsreg"
	"time-tracker/internal/application/usecases"
	"time-tracker/internal/domain"
)

type fakeRulesRepo struct{}

func (f *fakeRulesRepo) ListRules(context.Context) ([]domain.Rule, error)          { return nil, nil }
func (f *fakeRulesRepo) AddRule(context.Context, domain.RuleInput) (int64, error)  { return 1, nil }
func (f *fakeRulesRepo) UpdateRule(context.Context, int64, domain.RuleInput) error { return nil }
func (f *fakeRulesRepo) DeleteRule(context.Context, int64) error                   { return nil }
func (f *fakeRulesRepo) ApplyRulesetChanges(context.Context, domain.RulesetChanges) (domain.RulesetApplyResult, error) {
	return domain.RulesetApplyResult{}, nil
}
func (f *fakeRulesRepo) ListUnmappedEvents(context.Context, *string, int64) ([]domain.Event, error) {
	return nil, nil
}
func (f *fakeRulesRepo) ListUnmappedDates(context.Context, int64) ([]string, error) {
	return nil, nil
}
func (f *fakeRulesRepo) ListGroupedUnmappedEvents(context.Context, string, int64) ([]domain.GroupedEvent, error) {
	return nil, nil
}
func (f *fakeRulesRepo) ListBootstrapGroups(context.Context, domain.SuggestionQuery) ([]domain.GroupedEvent, error) {
	return []domain.GroupedEvent{{AppName: "Slack", WindowTitle: "Daily standup", EventCount: 3, TotalDurationMS: 180000}}, nil
}
func (f *fakeRulesRepo) ListAppSuggestions(context.Context, domain.SuggestionQuery) ([]domain.RuleSuggestion, error) {
	return nil, nil
}
func (f *fakeRulesRepo) ListTitleSuggestions(context.Context, domain.SuggestionQuery) ([]domain.RuleSuggestion, error) {
	title := "*standup*"
	return []domain.RuleSuggestion{{
		SuggestionType:   domain.SuggestionTypeAppAndTitle,
		AppPattern:       "Slack",
		TitlePattern:     &title,
		ProjectID:        10,
		ActivityID:       101,
		DisplayPath:      "web-app > meeting",
		Confidence:       88,
		ImpactCount:      3,
		ImpactDurationMS: 180000,
		EvidenceCount:    5,
	}}, nil
}
func (f *fakeRulesRepo) ApplyEventMappings(context.Context, []domain.EventMappingUpdate, bool) (int64, error) {
	return 0, nil
}
func (f *fakeRulesRepo) MapEventsByGroupWithLabel(context.Context, string, string, string, int64, int64, string) (int64, error) {
	return 1, nil
}
func (f *fakeRulesRepo) RecordSuggestionFeedback(context.Context, domain.SuggestionFeedback) error {
	return nil
}
func (f *fakeRulesRepo) RecordSuggestionRun(context.Context, domain.SuggestionRun) error { return nil }
func (f *fakeRulesRepo) CountMappedEvents(context.Context) (int64, error)                { return 10, nil }
func (f *fakeRulesRepo) CountActivities(context.Context) (int64, error)                  { return 3, nil }
func (f *fakeRulesRepo) CurrentProjectID(context.Context) (*int64, error)                { return nil, nil }
func (f *fakeRulesRepo) FindProjectIDByTitle(context.Context, string) (*int64, error) {
	return nil, nil
}
func (f *fakeRulesRepo) FindActivityIDByTitle(context.Context, int64, string) (*int64, error) {
	return nil, nil
}
func (f *fakeRulesRepo) ListAllProjects(context.Context) ([]domain.Project, error) {
	return []domain.Project{
		{ProjectID: 10, Title: "project a"},
	}, nil
}
func (f *fakeRulesRepo) ListActivitiesByProject(context.Context, int64) ([]domain.Activity, error) {
	return []domain.Activity{
		{ActivityID: 100, ProjectID: 10, Title: "development"},
		{ActivityID: 101, ProjectID: 10, Title: "meeting"},
	}, nil
}

type fakeReportsRepoForAPI struct{}

func (f *fakeReportsRepoForAPI) ListReportEvents(context.Context, string, *string) ([]domain.Event, error) {
	projectID := int64(10)
	activityID := int64(100)
	return []domain.Event{
		{
			ID:           1,
			TimestampMS:  1,
			DurationMS:   60_000,
			AppName:      "Code",
			WindowTitle:  "main.go",
			ProjectID:    &projectID,
			ActivityID:   &activityID,
			ProjectTitle: "project a",
		},
		{
			ID:          2,
			TimestampMS: 2,
			DurationMS:  30_000,
			AppName:     "Arc",
			WindowTitle: "Daily standup",
		},
	}, nil
}

type fakeProjectsRepoForAPI struct{}

func (fakeProjectsRepoForAPI) ListActiveProjects(context.Context) ([]domain.Project, error) {
	return []domain.Project{{ProjectID: 10, Title: "Project A", Metadata: "notes"}}, nil
}
func (fakeProjectsRepoForAPI) ListAllProjects(context.Context) ([]domain.Project, error) {
	return []domain.Project{
		{ProjectID: 10, Title: "Project A"},
		{ProjectID: 20, Title: "Project B"},
	}, nil
}
func (fakeProjectsRepoForAPI) ListArchivedProjects(context.Context) ([]domain.Project, error) {
	return []domain.Project{
		{ProjectID: 30, Title: "Project C"},
	}, nil
}
func (fakeProjectsRepoForAPI) CreateProject(_ context.Context, title, metadata string) (domain.Project, error) {
	return domain.Project{ProjectID: 99, Title: title, Metadata: metadata}, nil
}
func (fakeProjectsRepoForAPI) ListActivitiesByProject(_ context.Context, projectID int64) ([]domain.Activity, error) {
	switch projectID {
	case 10:
		return []domain.Activity{
			{ActivityID: 100, ProjectID: 10, Title: "Development"},
			{ActivityID: 101, ProjectID: 10, Title: "Meeting"},
		}, nil
	case 20:
		return []domain.Activity{
			{ActivityID: 200, ProjectID: 20, Title: "Review"},
		}, nil
	default:
		return nil, nil
	}
}
func (fakeProjectsRepoForAPI) ListAllActivities(context.Context) ([]domain.Activity, error) {
	return []domain.Activity{
		{ActivityID: 100, ProjectID: 10, Title: "Development"},
		{ActivityID: 101, ProjectID: 10, Title: "Meeting"},
		{ActivityID: 200, ProjectID: 20, Title: "Review"},
		{ActivityID: 300, ProjectID: 30, Title: "Archived work"},
	}, nil
}
func (fakeProjectsRepoForAPI) AddActivity(_ context.Context, projectID int64, title string) (domain.Activity, error) {
	return domain.Activity{ActivityID: 999, ProjectID: projectID, Title: title}, nil
}
func (fakeProjectsRepoForAPI) DeleteActivity(context.Context, int64) error { return nil }
func (fakeProjectsRepoForAPI) RemoveActivityFromProject(context.Context, int64, int64) error {
	return nil
}
func (fakeProjectsRepoForAPI) ActivateProject(context.Context, int64) error { return nil }
func (fakeProjectsRepoForAPI) ArchiveProject(context.Context, int64) error  { return nil }
func (fakeProjectsRepoForAPI) RestoreProject(context.Context, int64) error  { return nil }
func (fakeProjectsRepoForAPI) EndProject(context.Context, int64) error      { return nil }
func (fakeProjectsRepoForAPI) EndAllProjects(context.Context) error         { return nil }
func (fakeProjectsRepoForAPI) CurrentProject(context.Context) (string, *int64, error) {
	return "", nil, nil
}

type fakeSettingsRepoForAPI struct{}

func (fakeSettingsRepoForAPI) Load(context.Context) (domain.Settings, string, error) {
	return domain.Settings{}, "", nil
}
func (fakeSettingsRepoForAPI) Save(context.Context, domain.Settings) (string, error) {
	return "", nil
}

type fakeMutableProjectsRepoForAPI struct {
	projects   []domain.Project
	archived   []domain.Project
	activities []domain.Activity
	nextProjID int64
	nextActID  int64
}

func newFakeMutableProjectsRepoForAPI() *fakeMutableProjectsRepoForAPI {
	return &fakeMutableProjectsRepoForAPI{
		projects: []domain.Project{
			{ProjectID: 10, Title: "Project A", Metadata: "notes"},
			{ProjectID: 20, Title: "Project B"},
		},
		activities: []domain.Activity{
			{ActivityID: 100, ProjectID: 10, Title: "Development"},
			{ActivityID: 101, ProjectID: 10, Title: "Meeting"},
			{ActivityID: 200, ProjectID: 20, Title: "Review"},
		},
		nextProjID: 21,
		nextActID:  201,
	}
}

func (f *fakeMutableProjectsRepoForAPI) ListActiveProjects(context.Context) ([]domain.Project, error) {
	if len(f.projects) == 0 {
		return nil, nil
	}
	return []domain.Project{f.projects[0]}, nil
}

func (f *fakeMutableProjectsRepoForAPI) ListAllProjects(context.Context) ([]domain.Project, error) {
	out := make([]domain.Project, len(f.projects))
	copy(out, f.projects)
	return out, nil
}

func (f *fakeMutableProjectsRepoForAPI) ListArchivedProjects(context.Context) ([]domain.Project, error) {
	out := make([]domain.Project, len(f.archived))
	copy(out, f.archived)
	return out, nil
}

func (f *fakeMutableProjectsRepoForAPI) CreateProject(_ context.Context, title, metadata string) (domain.Project, error) {
	for _, project := range f.projects {
		if strings.EqualFold(project.Title, strings.TrimSpace(title)) {
			return domain.Project{}, domain.ErrProjectTitleConflict
		}
	}
	project := domain.Project{ProjectID: f.nextProjID, Title: strings.TrimSpace(title), Metadata: strings.TrimSpace(metadata)}
	f.nextProjID++
	f.projects = append(f.projects, project)
	return project, nil
}

func (f *fakeMutableProjectsRepoForAPI) ListActivitiesByProject(_ context.Context, projectID int64) ([]domain.Activity, error) {
	out := make([]domain.Activity, 0)
	for _, activity := range f.activities {
		if activity.ProjectID == projectID {
			out = append(out, activity)
		}
	}
	return out, nil
}

func (f *fakeMutableProjectsRepoForAPI) ListAllActivities(context.Context) ([]domain.Activity, error) {
	out := make([]domain.Activity, len(f.activities))
	copy(out, f.activities)
	return out, nil
}

func (f *fakeMutableProjectsRepoForAPI) AddActivity(_ context.Context, projectID int64, title string) (domain.Activity, error) {
	for _, project := range f.projects {
		if project.ProjectID == projectID {
			activity := domain.Activity{ActivityID: f.nextActID, ProjectID: projectID, Title: strings.TrimSpace(title)}
			f.nextActID++
			f.activities = append(f.activities, activity)
			return activity, nil
		}
	}
	return domain.Activity{}, domain.ErrProjectNotFound
}

func (f *fakeMutableProjectsRepoForAPI) DeleteActivity(_ context.Context, activityID int64) error {
	for i, activity := range f.activities {
		if activity.ActivityID == activityID {
			f.activities = append(f.activities[:i], f.activities[i+1:]...)
			return nil
		}
	}
	return domain.ErrActivityNotFound
}

func (f *fakeMutableProjectsRepoForAPI) RemoveActivityFromProject(_ context.Context, projectID, activityID int64) error {
	for i, activity := range f.activities {
		if activity.ActivityID == activityID && activity.ProjectID == projectID {
			f.activities = append(f.activities[:i], f.activities[i+1:]...)
			return nil
		}
	}
	return domain.ErrActivityNotFound
}

func (f *fakeMutableProjectsRepoForAPI) ActivateProject(context.Context, int64) error { return nil }

func (f *fakeMutableProjectsRepoForAPI) ArchiveProject(_ context.Context, projectID int64) error {
	for i, project := range f.projects {
		if project.ProjectID == projectID {
			f.projects = append(f.projects[:i], f.projects[i+1:]...)
			f.archived = append(f.archived, project)
			return nil
		}
	}
	return domain.ErrProjectNotFound
}

func (f *fakeMutableProjectsRepoForAPI) RestoreProject(_ context.Context, projectID int64) error {
	for i, project := range f.archived {
		if project.ProjectID == projectID {
			f.archived = append(f.archived[:i], f.archived[i+1:]...)
			f.projects = append(f.projects, project)
			return nil
		}
	}
	return domain.ErrProjectNotFound
}

func (f *fakeMutableProjectsRepoForAPI) EndProject(context.Context, int64) error { return nil }
func (f *fakeMutableProjectsRepoForAPI) EndAllProjects(context.Context) error    { return nil }
func (f *fakeMutableProjectsRepoForAPI) CurrentProject(context.Context) (string, *int64, error) {
	return "", nil, nil
}

func TestSuggestionsPartialRendersRows(t *testing.T) {
	app := &usecases.App{
		Rules: usecases.NewRulesUsecase(&fakeRulesRepo{}),
	}
	s, err := New(app)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	req := httptest.NewRequest(http.MethodGet, "/partials/suggestions", nil)
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Slack") {
		t.Fatalf("expected Slack in body, got %s", body)
	}
	if !strings.Contains(body, "Accept") {
		t.Fatalf("expected Accept button in body")
	}
}

func TestSuggestionsBootstrapPartialRendersRows(t *testing.T) {
	app := &usecases.App{
		Rules: usecases.NewRulesUsecase(&fakeRulesRepo{}),
	}
	s, err := New(app)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	req := httptest.NewRequest(http.MethodGet, "/partials/suggestions/bootstrap?date=2026-02-06&bootstrap_limit=10", nil)
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Slack") {
		t.Fatalf("expected bootstrap app in body, got %s", body)
	}
	if !strings.Contains(body, "Label") {
		t.Fatalf("expected label action in bootstrap table")
	}
}

func TestRulesPartialRendersDraftActions(t *testing.T) {
	app := &usecases.App{
		Rules: usecases.NewRulesUsecase(&fakeRulesRepo{}),
	}
	s, err := New(app)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	req := httptest.NewRequest(http.MethodGet, "/partials/rules", nil)
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Re-add Default Rules") {
		t.Fatalf("expected re-add defaults button")
	}
	if !strings.Contains(body, "Draft Preview") {
		t.Fatalf("expected draft preview heading")
	}
	if !strings.Contains(body, "Project + Activity") {
		t.Fatalf("expected project + activity selector")
	}
	if strings.Contains(body, "Project ID") {
		t.Fatalf("expected rules editor not to render project id field")
	}
}

func TestReportsPageRendersDayNavigationControls(t *testing.T) {
	app := &usecases.App{
		Reports: usecases.NewReportsUsecase(&fakeReportsRepoForAPI{}, fakeProjectsRepoForAPI{}, fakeSettingsRepoForAPI{}),
	}
	s, err := New(app)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/reports", nil)
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Previous") {
		t.Fatalf("expected previous day control")
	}
	if !strings.Contains(body, `type="date"`) {
		t.Fatalf("expected date input")
	}
	if !strings.Contains(body, "View Range") {
		t.Fatalf("expected range refresh button")
	}
	if !strings.Contains(body, "Apply Rules") {
		t.Fatalf("expected apply rules action on reports page")
	}
}

func TestReportsPartialShowsDateContext(t *testing.T) {
	app := &usecases.App{
		Reports: usecases.NewReportsUsecase(&fakeReportsRepoForAPI{}, fakeProjectsRepoForAPI{}, fakeSettingsRepoForAPI{}),
	}
	s, err := New(app)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/partials/reports?range=all&date=2026-02-07", nil)
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "2026-02-07") {
		t.Fatalf("expected selected date context, got %s", body)
	}
	if !strings.Contains(body, "Top Window Titles") {
		t.Fatalf("expected detailed windows table in reports partial")
	}
}

func TestReportsPartialShowsRangeContextWithoutDate(t *testing.T) {
	app := &usecases.App{
		Reports: usecases.NewReportsUsecase(&fakeReportsRepoForAPI{}, fakeProjectsRepoForAPI{}, fakeSettingsRepoForAPI{}),
	}
	s, err := New(app)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/partials/reports?range=week", nil)
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Range") {
		t.Fatalf("expected range context, got %s", body)
	}
	if !strings.Contains(body, "Mapped") || !strings.Contains(body, "Unmapped") {
		t.Fatalf("expected mapped/unmapped details in reports partial")
	}
}

func TestReportsApplyRulesRendersSummary(t *testing.T) {
	app := &usecases.App{
		Reports: usecases.NewReportsUsecase(&fakeReportsRepoForAPI{}, fakeProjectsRepoForAPI{}, fakeSettingsRepoForAPI{}),
		Rules:   usecases.NewRulesUsecase(&fakeRulesRepo{}),
	}
	s, err := New(app)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	form := url.Values{}
	form.Set("range", "today")
	form.Set("date", "2026-02-07")
	form.Set("dry_run", "1")
	req := httptest.NewRequest(http.MethodPost, "/reports/apply-rules", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Dry run rules for 2026-02-07") {
		t.Fatalf("expected dry-run summary, got %s", body)
	}
}

func TestProjectsPartialRendersActivitiesPerProject(t *testing.T) {
	app := &usecases.App{
		Projects: usecases.NewProjectsUsecase(fakeProjectsRepoForAPI{}),
	}
	s, err := New(app)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/partials/projects", nil)
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Project A") || !strings.Contains(body, "Project B") {
		t.Fatalf("expected projects in body, got %s", body)
	}
	if !strings.Contains(body, "Create Project") {
		t.Fatalf("expected create project section, got %s", body)
	}
	if !strings.Contains(body, "Mapping Targets") {
		t.Fatalf("expected mapping targets section, got %s", body)
	}
	if !strings.Contains(body, "Project A &gt; Development") && !strings.Contains(body, "Project A > Development") {
		t.Fatalf("expected project target list, got %s", body)
	}
}

func TestProjectsCreateEndpointRendersUpdatedPanel(t *testing.T) {
	repo := newFakeMutableProjectsRepoForAPI()
	app := &usecases.App{
		Projects: usecases.NewProjectsUsecase(repo),
	}
	s, err := New(app)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	form := url.Values{}
	form.Set("title", "Project Z")
	form.Set("metadata", "new scope")
	req := httptest.NewRequest(http.MethodPost, "/projects/create", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rr.Code, rr.Body.String())
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Created project") {
		t.Fatalf("expected create summary, got %s", body)
	}
	if !strings.Contains(body, "Project Z") {
		t.Fatalf("expected new project in response, got %s", body)
	}
}

func TestProjectsArchiveAndRestoreEndpoints(t *testing.T) {
	repo := newFakeMutableProjectsRepoForAPI()
	app := &usecases.App{
		Projects: usecases.NewProjectsUsecase(repo),
	}
	s, err := New(app)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	archiveReq := httptest.NewRequest(http.MethodPost, "/projects/10/archive", nil)
	archiveRR := httptest.NewRecorder()
	s.Routes().ServeHTTP(archiveRR, archiveReq)
	if archiveRR.Code != http.StatusOK {
		t.Fatalf("expected 200 on archive, got %d", archiveRR.Code)
	}
	if !strings.Contains(archiveRR.Body.String(), "Project archived") {
		t.Fatalf("expected archive summary, got %s", archiveRR.Body.String())
	}

	restoreReq := httptest.NewRequest(http.MethodPost, "/projects/10/restore", nil)
	restoreRR := httptest.NewRecorder()
	s.Routes().ServeHTTP(restoreRR, restoreReq)
	if restoreRR.Code != http.StatusOK {
		t.Fatalf("expected 200 on restore, got %d", restoreRR.Code)
	}
	if !strings.Contains(restoreRR.Body.String(), "Project restored") {
		t.Fatalf("expected restore summary, got %s", restoreRR.Body.String())
	}
}

func TestProjectsAddAndRemoveActivityEndpoints(t *testing.T) {
	repo := newFakeMutableProjectsRepoForAPI()
	app := &usecases.App{
		Projects: usecases.NewProjectsUsecase(repo),
	}
	s, err := New(app)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	form := url.Values{}
	form.Set("title", "Planning")
	addReq := httptest.NewRequest(http.MethodPost, "/projects/10/activities/add", strings.NewReader(form.Encode()))
	addReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	addRR := httptest.NewRecorder()
	s.Routes().ServeHTTP(addRR, addReq)
	if addRR.Code != http.StatusOK {
		t.Fatalf("expected 200 on add activity, got %d", addRR.Code)
	}
	if !strings.Contains(addRR.Body.String(), "Added activity") || !strings.Contains(addRR.Body.String(), "Planning") {
		t.Fatalf("expected add activity summary and title, got %s", addRR.Body.String())
	}

	removeReq := httptest.NewRequest(http.MethodPost, "/projects/10/activities/201/remove", nil)
	removeRR := httptest.NewRecorder()
	s.Routes().ServeHTTP(removeRR, removeReq)
	if removeRR.Code != http.StatusOK {
		t.Fatalf("expected 200 on remove activity, got %d", removeRR.Code)
	}
	if !strings.Contains(removeRR.Body.String(), "Activity removed from project") {
		t.Fatalf("expected remove summary, got %s", removeRR.Body.String())
	}
}

func TestIntegrationsHubRendersTidsregCard(t *testing.T) {
	s, err := New(&usecases.App{})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/integrations", nil)
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Tidsreg") {
		t.Fatalf("expected tidsreg card in body")
	}
	if !strings.Contains(body, "href=\"/integrations/tidsreg\"") {
		t.Fatalf("expected tidsreg card link in body")
	}
}

func TestDocsPageRendersMarkdownAndActiveNav(t *testing.T) {
	s, err := New(&usecases.App{})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/docs", nil)
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Getting Started") {
		t.Fatalf("expected getting started heading in body")
	}
	if !strings.Contains(body, "href=\"/docs\" class=\"active\"") {
		t.Fatalf("expected docs nav link to be active")
	}
	if !strings.Contains(body, "language-mermaid") {
		t.Fatalf("expected mermaid code block in rendered markdown")
	}
}

func TestTidsregIntegrationPageRendersLoginForm(t *testing.T) {
	s, err := New(&usecases.App{})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/integrations/tidsreg", nil)
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "autocomplete=\"username\"") {
		t.Fatalf("expected username autocomplete in body")
	}
	if !strings.Contains(body, "Load Step 1: Customers") {
		t.Fatalf("expected tidsreg login form in body")
	}
	if !strings.Contains(body, "id=\"tidsreg-loader\"") {
		t.Fatalf("expected tidsreg loader in body")
	}
}

func TestTidsregCustomersTemplateDefaultsToUnchecked(t *testing.T) {
	s, err := New(&usecases.App{})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	rr := httptest.NewRecorder()
	s.render(rr, "partials/tidsreg_customers", pageData{
		TidsregCustomers: []tidsregmodel.Customer{{CustomerID: 1, Name: "Trifork"}},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if strings.Contains(body, "name=\"customer_ids\" value=\"1\" checked") {
		t.Fatalf("expected customer checkbox to start unchecked")
	}
	if !strings.Contains(body, "hx-post=\"/integrations/tidsreg/projects\"") {
		t.Fatalf("expected customers step to post to projects route")
	}
	if !strings.Contains(body, "Select All / None") {
		t.Fatalf("expected check/uncheck button in customers step")
	}
	if !strings.Contains(body, "hx-indicator=\"#tidsreg-loader\"") {
		t.Fatalf("expected customers step loader indicator wiring")
	}
}

func TestTidsregProjectsTemplateRendersProjectSelection(t *testing.T) {
	s, err := New(&usecases.App{})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	rr := httptest.NewRecorder()
	s.render(rr, "partials/tidsreg_projects", pageData{
		TidsregProjects: []tidsregmodel.Project{{
			ProjectID:    42,
			CustomerID:   7,
			Name:         "Portal",
			CustomerName: "Trifork",
		}},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "name=\"project_ids\" value=\"42\"") {
		t.Fatalf("expected project checkbox in projects step")
	}
	if !strings.Contains(body, "Select All / None") {
		t.Fatalf("expected check/uncheck button in projects step")
	}
	if !strings.Contains(body, "hx-indicator=\"#tidsreg-loader\"") {
		t.Fatalf("expected projects step loader indicator wiring")
	}
}

func TestTidsregPreviewTemplateRendersActivityNames(t *testing.T) {
	s, err := New(&usecases.App{})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	rr := httptest.NewRecorder()
	s.render(rr, "partials/tidsreg_preview", pageData{
		TidsregPreview: tidsregmodel.ImportPreview{
			Candidates: []tidsregmodel.ImportCandidate{{
				Key:          "1:10:100",
				CustomerName: "Trifork",
				ProjectName:  "Portal",
				PhaseName:    "Build",
				TargetTitle:  "Trifork > Portal > Build",
				Activities: []tidsregmodel.Activity{
					{ActivityID: 1, Name: "Development"},
					{ActivityID: 2, Name: "Meeting"},
					{ActivityID: 3, Name: "Design"},
				},
			}},
		},
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Development, Meeting, Design") {
		t.Fatalf("expected activity names in preview body, got %s", body)
	}
}

func TestRequestLoggingMiddlewareLogsMethodPathAndStatus(t *testing.T) {
	s, err := New(&usecases.App{})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}
	var buf bytes.Buffer
	s.logger = log.New(&buf, "", 0)

	handler := s.requestLoggingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte("ok"))
	}))

	req := httptest.NewRequest(http.MethodPost, "/rules?draft=true", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d", rr.Code)
	}
	logLine := buf.String()
	if !strings.Contains(logLine, "method=POST") {
		t.Fatalf("expected method in log, got %s", logLine)
	}
	if !strings.Contains(logLine, "path=/rules?draft=true") {
		t.Fatalf("expected path in log, got %s", logLine)
	}
	if !strings.Contains(logLine, "status=201") {
		t.Fatalf("expected status in log, got %s", logLine)
	}
	if !strings.Contains(logLine, "duration_ms=") {
		t.Fatalf("expected duration in log, got %s", logLine)
	}
}

func TestRecoverMiddlewareReturns500AndLogsPanic(t *testing.T) {
	s, err := New(&usecases.App{})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	var buf bytes.Buffer
	s.logger = log.New(&buf, "", 0)

	handler := s.requestLoggingMiddleware(s.recoverMiddleware(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic("boom")
	})))

	req := httptest.NewRequest(http.MethodGet, "/panic", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d", rr.Code)
	}
	logLine := buf.String()
	if !strings.Contains(logLine, "panic method=GET path=/panic err=boom") {
		t.Fatalf("expected panic log, got %s", logLine)
	}
	if !strings.Contains(logLine, "status=500") {
		t.Fatalf("expected status log, got %s", logLine)
	}
}

func TestRequestLoggingMiddlewareIncludesErrorBody(t *testing.T) {
	s, err := New(&usecases.App{})
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	var buf bytes.Buffer
	s.logger = log.New(&buf, "", 0)

	handler := s.requestLoggingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))

	req := httptest.NewRequest(http.MethodGet, "/failing", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d", rr.Code)
	}
	logLine := buf.String()
	if !strings.Contains(logLine, "status=500") {
		t.Fatalf("expected status in log, got %s", logLine)
	}
	if !strings.Contains(logLine, `error_body="boom"`) {
		t.Fatalf("expected error body in log, got %s", logLine)
	}
}

func TestRulesDraftAddFromSelectionLogsFailureDetails(t *testing.T) {
	app := &usecases.App{
		Rules: usecases.NewRulesUsecase(&fakeRulesRepo{}),
	}
	s, err := New(app)
	if err != nil {
		t.Fatalf("new server: %v", err)
	}

	var buf bytes.Buffer
	s.logger = log.New(&buf, "", 0)

	form := url.Values{}
	form.Set("selected_idx", "0")
	form.Set("group_app_0", "Google Chrome")
	form.Set("group_title_0", "Daily standup")
	form.Set("action_type", "assign_explicit")
	form.Set("priority", "100")
	form.Set("target_path", encodeRuleTargetPath("project a", "meeting"))

	req := httptest.NewRequest(http.MethodPost, "/rules/draft/add-from-selection", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rr := httptest.NewRecorder()
	s.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d body=%s", rr.Code, rr.Body.String())
	}
	logLine := buf.String()
	if !strings.Contains(logLine, "rules_add_from_selection parsed") {
		t.Fatalf("expected parsed log, got %s", logLine)
	}
	if !strings.Contains(logLine, "target_project=\"project a\"") {
		t.Fatalf("expected target project in log, got %s", logLine)
	}
	if !strings.Contains(logLine, "handler_error method=POST path=/rules/draft/add-from-selection") {
		t.Fatalf("expected handler error log, got %s", logLine)
	}
}

func TestRuleTargetPathEncodingRoundTrip(t *testing.T) {
	encoded := encodeRuleTargetPath("project a", "development")
	project, activity, err := decodeRuleTargetPath(encoded)
	if err != nil {
		t.Fatalf("decode rule target failed: %v", err)
	}
	if project != "project a" || activity != "development" {
		t.Fatalf("unexpected decoded values project=%q activity=%q", project, activity)
	}
}
