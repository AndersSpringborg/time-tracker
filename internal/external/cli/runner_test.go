package cli

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"time-tracker/internal/application/usecases"
	"time-tracker/internal/domain"
)

func TestRunnerHelpJSONForRules(t *testing.T) {
	r := &Runner{App: &usecases.App{Help: usecases.NewHelpUsecase()}}
	var out bytes.Buffer
	var errOut bytes.Buffer

	code := r.Run(context.Background(), []string{"help", "--format", "json", "rules"}, &out, &errOut)
	if code != 0 {
		t.Fatalf("expected exit code 0, got %d stderr=%s", code, errOut.String())
	}
	if !strings.Contains(out.String(), `"command": "rules"`) {
		t.Fatalf("expected rules schema json, got: %s", out.String())
	}
	if !strings.Contains(out.String(), `"side_effects"`) {
		t.Fatalf("expected side_effects in output")
	}
}

type fakeLifecycle struct {
	installErr error
	status     domain.LifecycleStatus
}

func (f *fakeLifecycle) Install(context.Context) error                 { return f.installErr }
func (f *fakeLifecycle) Uninstall(context.Context) error               { return nil }
func (f *fakeLifecycle) Start(context.Context) error                   { return nil }
func (f *fakeLifecycle) Stop(context.Context) error                    { return nil }
func (f *fakeLifecycle) Status(context.Context) domain.LifecycleStatus { return f.status }

type fakeRunnerProjectsRepo struct {
	projects    []domain.Project
	archived    []domain.Project
	activities  []domain.Activity
	nextProjID  int64
	nextActID   int64
	currentID   *int64
	currentName string
}

func newFakeRunnerProjectsRepo() *fakeRunnerProjectsRepo {
	return &fakeRunnerProjectsRepo{
		nextProjID: 1,
		nextActID:  1,
	}
}

func (f *fakeRunnerProjectsRepo) ListActiveProjects(context.Context) ([]domain.Project, error) {
	if f.currentID == nil {
		return nil, nil
	}
	for _, project := range f.projects {
		if project.ProjectID == *f.currentID {
			return []domain.Project{project}, nil
		}
	}
	return nil, nil
}

func (f *fakeRunnerProjectsRepo) ListAllProjects(context.Context) ([]domain.Project, error) {
	out := make([]domain.Project, len(f.projects))
	copy(out, f.projects)
	return out, nil
}

func (f *fakeRunnerProjectsRepo) ListArchivedProjects(context.Context) ([]domain.Project, error) {
	out := make([]domain.Project, len(f.archived))
	copy(out, f.archived)
	return out, nil
}

func (f *fakeRunnerProjectsRepo) CreateProject(_ context.Context, title, metadata string) (domain.Project, error) {
	normalized := strings.TrimSpace(title)
	if normalized == "" {
		return domain.Project{}, domain.ErrProjectTitleRequired
	}
	for _, project := range f.projects {
		if strings.EqualFold(strings.TrimSpace(project.Title), normalized) {
			return domain.Project{}, domain.ErrProjectTitleConflict
		}
	}
	project := domain.Project{
		ProjectID: f.nextProjID,
		Title:     normalized,
		Metadata:  strings.TrimSpace(metadata),
	}
	f.nextProjID++
	f.projects = append(f.projects, project)
	return project, nil
}

func (f *fakeRunnerProjectsRepo) ListActivitiesByProject(_ context.Context, projectID int64) ([]domain.Activity, error) {
	out := make([]domain.Activity, 0)
	for _, activity := range f.activities {
		if activity.ProjectID == projectID {
			out = append(out, activity)
		}
	}
	return out, nil
}

func (f *fakeRunnerProjectsRepo) ListAllActivities(context.Context) ([]domain.Activity, error) {
	out := make([]domain.Activity, len(f.activities))
	copy(out, f.activities)
	return out, nil
}

func (f *fakeRunnerProjectsRepo) AddActivity(_ context.Context, projectID int64, title string) (domain.Activity, error) {
	titleValue := strings.TrimSpace(title)
	if titleValue == "" {
		return domain.Activity{}, domain.ErrActivityTitleRequired
	}
	projectExists := false
	for _, project := range f.projects {
		if project.ProjectID == projectID {
			projectExists = true
			break
		}
	}
	if !projectExists {
		return domain.Activity{}, domain.ErrProjectNotFound
	}
	for _, activity := range f.activities {
		if activity.ProjectID == projectID && strings.EqualFold(strings.TrimSpace(activity.Title), titleValue) {
			return domain.Activity{}, domain.ErrActivityTitleConflict
		}
	}
	activity := domain.Activity{
		ActivityID: f.nextActID,
		ProjectID:  projectID,
		Title:      titleValue,
	}
	f.nextActID++
	f.activities = append(f.activities, activity)
	return activity, nil
}

func (f *fakeRunnerProjectsRepo) DeleteActivity(_ context.Context, activityID int64) error {
	for i, activity := range f.activities {
		if activity.ActivityID == activityID {
			f.activities = append(f.activities[:i], f.activities[i+1:]...)
			return nil
		}
	}
	return domain.ErrActivityNotFound
}

func (f *fakeRunnerProjectsRepo) RemoveActivityFromProject(_ context.Context, projectID, activityID int64) error {
	for i, activity := range f.activities {
		if activity.ActivityID == activityID && activity.ProjectID == projectID {
			f.activities = append(f.activities[:i], f.activities[i+1:]...)
			return nil
		}
	}
	return domain.ErrActivityNotFound
}

func (f *fakeRunnerProjectsRepo) ActivateProject(_ context.Context, projectID int64) error {
	for _, project := range f.projects {
		if project.ProjectID == projectID {
			id := projectID
			f.currentID = &id
			f.currentName = project.Title
			return nil
		}
	}
	return domain.ErrProjectNotFound
}

func (f *fakeRunnerProjectsRepo) ArchiveProject(_ context.Context, projectID int64) error {
	for i, project := range f.projects {
		if project.ProjectID == projectID {
			f.projects = append(f.projects[:i], f.projects[i+1:]...)
			f.archived = append(f.archived, project)
			if f.currentID != nil && *f.currentID == projectID {
				f.currentID = nil
				f.currentName = ""
			}
			return nil
		}
	}
	return domain.ErrProjectNotFound
}

func (f *fakeRunnerProjectsRepo) RestoreProject(_ context.Context, projectID int64) error {
	for i, project := range f.archived {
		if project.ProjectID == projectID {
			f.archived = append(f.archived[:i], f.archived[i+1:]...)
			f.projects = append(f.projects, project)
			return nil
		}
	}
	return domain.ErrProjectNotFound
}

func (f *fakeRunnerProjectsRepo) EndProject(_ context.Context, projectID int64) error {
	if f.currentID != nil && *f.currentID == projectID {
		f.currentID = nil
		f.currentName = ""
	}
	return nil
}

func (f *fakeRunnerProjectsRepo) EndAllProjects(context.Context) error {
	f.currentID = nil
	f.currentName = ""
	return nil
}

func (f *fakeRunnerProjectsRepo) CurrentProject(context.Context) (string, *int64, error) {
	if f.currentID == nil {
		return "None", nil, nil
	}
	return f.currentName, f.currentID, nil
}

func TestRunnerStatusPrintsAccessibilityHintWhenNoPID(t *testing.T) {
	tmp := t.TempDir()
	errLog := filepath.Join(tmp, "worker.err.log")
	if err := os.WriteFile(errLog, []byte("ERROR: Accessibility permission required!"), 0o644); err != nil {
		t.Fatalf("write err log: %v", err)
	}

	orig := workerErrLogPath
	workerErrLogPath = errLog
	t.Cleanup(func() { workerErrLogPath = orig })

	lc := &fakeLifecycle{status: domain.LifecycleStatus{Loaded: true, State: "spawn scheduled"}}
	r := &Runner{
		App: &usecases.App{
			Lifecycle: usecases.NewLifecycleUsecase(lc),
		},
		WorkerPath: "/Users/test/.local/bin/tt-worker",
	}

	var out bytes.Buffer
	var errOut bytes.Buffer
	code := r.Run(context.Background(), []string{"status"}, &out, &errOut)
	if code != 0 {
		t.Fatalf("expected exit code 0, got %d stderr=%s", code, errOut.String())
	}

	got := out.String()
	if !strings.Contains(got, "accessibility-worker: /Users/test/.local/bin/tt-worker") {
		t.Fatalf("expected accessibility worker hint, got: %s", got)
	}
	if !strings.Contains(got, "recent worker logs indicate Accessibility permission is still denied") {
		t.Fatalf("expected accessibility log hint, got: %s", got)
	}
}

func TestRunnerInstallPrintsAccessibilityHint(t *testing.T) {
	lc := &fakeLifecycle{}
	r := &Runner{
		App: &usecases.App{
			Lifecycle: usecases.NewLifecycleUsecase(lc),
		},
		WorkerPath: "/Users/test/.local/bin/tt-worker",
	}

	var out bytes.Buffer
	var errOut bytes.Buffer
	code := r.Run(context.Background(), []string{"install"}, &out, &errOut)
	if code != 0 {
		t.Fatalf("expected exit code 0, got %d stderr=%s", code, errOut.String())
	}

	got := out.String()
	if !strings.Contains(got, "installed and started launchd worker") {
		t.Fatalf("expected install success output, got: %s", got)
	}
	if !strings.Contains(got, "accessibility-worker: /Users/test/.local/bin/tt-worker") {
		t.Fatalf("expected accessibility hint, got: %s", got)
	}
}

func TestBuildTimeTrackerRulesPresetDefaults(t *testing.T) {
	rules := buildTimeTrackerRulesPreset("", "", true)
	if len(rules) != 4 {
		t.Fatalf("expected 4 rules, got %d", len(rules))
	}
	for _, rule := range rules {
		if !strings.HasPrefix(rule.RuleKey, "preset.time_tracker.") {
			t.Fatalf("unexpected rule key: %s", rule.RuleKey)
		}
		if rule.ActionType != domain.RuleActionAssignActivityCurrent {
			t.Fatalf("expected assign_activity_in_current_project action, got %s", rule.ActionType)
		}
		if rule.ActionActivityName == "" {
			t.Fatalf("expected action activity name for %s", rule.RuleKey)
		}
	}
}

func TestBuildTimeTrackerRulesPresetCustomActivitiesAndNoMeeting(t *testing.T) {
	rules := buildTimeTrackerRulesPreset("coding", "sync", false)
	if len(rules) != 3 {
		t.Fatalf("expected 3 rules when meeting disabled, got %d", len(rules))
	}
	for _, rule := range rules {
		if strings.Contains(rule.RuleKey, "meeting") {
			t.Fatalf("did not expect meeting rule when disabled")
		}
		if rule.ActionActivityName != "coding" {
			t.Fatalf("expected coding activity, got %s", rule.ActionActivityName)
		}
	}
}

func TestRunnerProjectsCreateAndAddActivityByProjectName(t *testing.T) {
	repo := newFakeRunnerProjectsRepo()
	r := &Runner{
		App: &usecases.App{
			Projects: usecases.NewProjectsUsecase(repo),
		},
	}

	var out bytes.Buffer
	var errOut bytes.Buffer
	ctx := context.Background()

	code := r.Run(ctx, []string{"projects", "create", "--title", "time-tracker", "--metadata", "local", "--format", "json"}, &out, &errOut)
	if code != 0 {
		t.Fatalf("create failed: code=%d stderr=%s", code, errOut.String())
	}
	if !strings.Contains(out.String(), `"title": "time-tracker"`) {
		t.Fatalf("expected created project title, got: %s", out.String())
	}

	out.Reset()
	errOut.Reset()
	code = r.Run(ctx, []string{"projects", "add-activity", "--project", "time-tracker", "--title", "development", "--format", "json"}, &out, &errOut)
	if code != 0 {
		t.Fatalf("add-activity failed: code=%d stderr=%s", code, errOut.String())
	}
	if !strings.Contains(out.String(), `"project_title": "time-tracker"`) {
		t.Fatalf("expected project title in add-activity output, got: %s", out.String())
	}
	if !strings.Contains(out.String(), `"title": "development"`) {
		t.Fatalf("expected activity title in add-activity output, got: %s", out.String())
	}

	out.Reset()
	errOut.Reset()
	code = r.Run(ctx, []string{"projects", "activities", "--project", "time-tracker", "--format", "json"}, &out, &errOut)
	if code != 0 {
		t.Fatalf("activities failed: code=%d stderr=%s", code, errOut.String())
	}
	if !strings.Contains(out.String(), `"project_title": "time-tracker"`) {
		t.Fatalf("expected project title in activities output, got: %s", out.String())
	}
	if !strings.Contains(out.String(), `"title": "development"`) {
		t.Fatalf("expected activity title in activities output, got: %s", out.String())
	}
}

func TestRunnerProjectsAddAndCurrentByProjectName(t *testing.T) {
	repo := newFakeRunnerProjectsRepo()
	project, err := repo.CreateProject(context.Background(), "time-tracker", "")
	if err != nil {
		t.Fatalf("seed project failed: %v", err)
	}
	r := &Runner{
		App: &usecases.App{
			Projects: usecases.NewProjectsUsecase(repo),
		},
	}

	var out bytes.Buffer
	var errOut bytes.Buffer
	ctx := context.Background()

	code := r.Run(ctx, []string{"projects", "add", "--project", "time-tracker"}, &out, &errOut)
	if code != 0 {
		t.Fatalf("add project failed: code=%d stderr=%s", code, errOut.String())
	}
	expected := fmt.Sprintf("project activated: %d %s", project.ProjectID, project.Title)
	if !strings.Contains(out.String(), expected) {
		t.Fatalf("expected activation output %q, got: %s", expected, out.String())
	}

	out.Reset()
	errOut.Reset()
	code = r.Run(ctx, []string{"projects", "current"}, &out, &errOut)
	if code != 0 {
		t.Fatalf("current project failed: code=%d stderr=%s", code, errOut.String())
	}
	if !strings.Contains(out.String(), "Current project:") || !strings.Contains(out.String(), "time-tracker") {
		t.Fatalf("expected current project output with name, got: %s", out.String())
	}
}
