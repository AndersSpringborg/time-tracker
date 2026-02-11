package duckdb

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"

	"time-tracker/internal/domain"
)

func openTestStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(":memory:")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	return s
}

func seedProjectActivity(t *testing.T, s *Store) {
	t.Helper()
	ctx := context.Background()
	queries := []string{
		"INSERT INTO customers (customer_id, name) VALUES (1, 'internal')",
		"INSERT INTO projects (project_id, customer_id, name, title, metadata) VALUES (10, 1, 'web-app', 'web-app', 'notes')",
		"INSERT INTO activities (activity_id, project_id, name, title) VALUES (100, 10, 'development', 'development')",
		"INSERT INTO activities (activity_id, project_id, name, title) VALUES (101, 10, 'meeting', 'meeting')",
		"INSERT INTO project_activities (project_id, activity_id) VALUES (10, 100)",
		"INSERT INTO project_activities (project_id, activity_id) VALUES (10, 101)",
	}
	for _, q := range queries {
		if _, err := s.db.ExecContext(ctx, q); err != nil {
			t.Fatalf("seed query failed: %v", err)
		}
	}
}

func TestApplyEventMappingsUpdatesEvents(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	seedProjectActivity(t, s)
	ctx := context.Background()

	if _, err := s.db.ExecContext(ctx, `INSERT INTO events (id, timestamp_ms, app_name, window_title, duration_ms, manually_mapped) VALUES (1, 100, 'Slack', 'daily standup', 60000, false)`); err != nil {
		t.Fatalf("insert event: %v", err)
	}

	n, err := s.ApplyEventMappings(ctx, []domain.EventMappingUpdate{{
		EventID:    1,
		ProjectID:  10,
		ActivityID: 101,
	}}, true)
	if err != nil {
		t.Fatalf("apply event mappings: %v", err)
	}
	if n != 1 {
		t.Fatalf("expected 1 updated row, got %d", n)
	}

	var projectID, activityID int64
	var manual bool
	if err := s.db.QueryRowContext(ctx, `SELECT project_id, activity_id, manually_mapped FROM events WHERE id = 1`).Scan(&projectID, &activityID, &manual); err != nil {
		t.Fatalf("query event: %v", err)
	}
	if projectID != 10 || activityID != 101 || !manual {
		t.Fatalf("unexpected event mapping project=%d activity=%d manual=%v", projectID, activityID, manual)
	}
}

func TestApplyRulesetChangesAddsUpdatesAndDeletes(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	seedProjectActivity(t, s)
	ctx := context.Background()

	if _, err := s.db.ExecContext(ctx, `
INSERT INTO mapping_rules (
	rule_key, source, priority, app_pattern, title_pattern, project_id, activity_id, follow_previous,
	action_type, action_project_title, action_activity_title, pattern_format
) VALUES ('rule.original', 'user', 100, '(?i)^Code$', '(?i)^.*$', 10, 100, false, 'assign_explicit', NULL, NULL, 'regex')
`); err != nil {
		t.Fatalf("insert original rule: %v", err)
	}
	var existingID int64
	if err := s.db.QueryRowContext(ctx, `SELECT id FROM mapping_rules WHERE rule_key = 'rule.original'`).Scan(&existingID); err != nil {
		t.Fatalf("query original rule id: %v", err)
	}

	p10 := int64(10)
	a100 := int64(100)
	result, err := s.ApplyRulesetChanges(ctx, domain.RulesetChanges{
		Adds: []domain.RuleInput{
			{
				RuleKey:      "rule.new",
				Source:       domain.RuleSourceUser,
				Priority:     200,
				AppPattern:   "(?i)^Arc$",
				TitlePattern: "(?i)^.*zoom.*$",
				ProjectID:    &p10,
				ActivityID:   &a100,
				ActionType:   domain.RuleActionAssignExplicit,
			},
		},
		Updates: []domain.RuleUpdate{
			{
				ID: existingID,
				Rule: domain.RuleInput{
					RuleKey:            "rule.original",
					Source:             domain.RuleSourceUser,
					Priority:           300,
					AppPattern:         "(?i)^Firefox$",
					TitlePattern:       "(?i)^.*teams.*$",
					ActionType:         domain.RuleActionAssignActivityCurrent,
					ActionActivityName: "meeting",
				},
			},
		},
		Deletes: []int64{},
	})
	if err != nil {
		t.Fatalf("apply ruleset changes: %v", err)
	}
	if result.Added != 1 || result.Updated != 1 || result.Deleted != 0 {
		t.Fatalf("unexpected apply result: %+v", result)
	}

	rules, err := s.ListRules(ctx)
	if err != nil {
		t.Fatalf("list rules failed: %v", err)
	}
	if len(rules) != 2 {
		t.Fatalf("expected 2 rules, got %d", len(rules))
	}
	if rules[0].ActionType == "" {
		t.Fatalf("expected hydrated action type")
	}
}

func TestFindProjectAndActivityByTitle(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	seedProjectActivity(t, s)
	ctx := context.Background()

	projectID, err := s.FindProjectIDByTitle(ctx, "WEB-APP")
	if err != nil {
		t.Fatalf("find project by title failed: %v", err)
	}
	if projectID == nil || *projectID != 10 {
		t.Fatalf("expected project id 10, got %+v", projectID)
	}

	activityID, err := s.FindActivityIDByTitle(ctx, 10, "MEETING")
	if err != nil {
		t.Fatalf("find activity by title failed: %v", err)
	}
	if activityID == nil || *activityID != 101 {
		t.Fatalf("expected activity id 101, got %+v", activityID)
	}
}

func TestListActivitiesByProject(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	seedProjectActivity(t, s)
	ctx := context.Background()

	activities, err := s.ListActivitiesByProject(ctx, 10)
	if err != nil {
		t.Fatalf("list activities by project failed: %v", err)
	}
	if len(activities) != 2 {
		t.Fatalf("expected 2 activities, got %d", len(activities))
	}
	if activities[0].Title != "development" || activities[1].Title != "meeting" {
		t.Fatalf("unexpected activity order: %+v", activities)
	}
}

func TestListActivitiesByProjectUsesCompositeLinks(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	ctx := context.Background()

	if _, err := s.db.ExecContext(ctx, `INSERT INTO customers (customer_id, name) VALUES (1, 'internal')`); err != nil {
		t.Fatalf("seed customer failed: %v", err)
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO projects (project_id, customer_id, name, title, metadata) VALUES (10, 1, 'web-app', 'web-app', '')`); err != nil {
		t.Fatalf("seed project failed: %v", err)
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO projects (project_id, customer_id, name, title, metadata) VALUES (11, 1, 'service', 'service', '')`); err != nil {
		t.Fatalf("seed project 11 failed: %v", err)
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO activities (activity_id, project_id, name, title) VALUES (100, 0, 'development', 'development')`); err != nil {
		t.Fatalf("seed activity failed: %v", err)
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO project_activities (project_id, activity_id) VALUES (10, 100)`); err != nil {
		t.Fatalf("seed composite link 10 failed: %v", err)
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO project_activities (project_id, activity_id) VALUES (11, 100)`); err != nil {
		t.Fatalf("seed composite link 11 failed: %v", err)
	}

	activities, err := s.ListActivitiesByProject(ctx, 11)
	if err != nil {
		t.Fatalf("list activities by project failed: %v", err)
	}
	if len(activities) != 1 || activities[0].ActivityID != 100 {
		t.Fatalf("expected linked shared activity for project 11, got %+v", activities)
	}
}

func TestAddRuleStoresProjectActivityCompositeKey(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	seedProjectActivity(t, s)
	ctx := context.Background()

	projectID := int64(10)
	activityID := int64(100)
	_, err := s.AddRule(ctx, domain.RuleInput{
		RuleKey:      "rule.composite",
		Source:       domain.RuleSourceUser,
		Priority:     100,
		AppPattern:   "(?i)^Code$",
		TitlePattern: "(?i)^.*$",
		ProjectID:    &projectID,
		ActivityID:   &activityID,
		ActionType:   domain.RuleActionAssignExplicit,
	})
	if err != nil {
		t.Fatalf("add rule failed: %v", err)
	}

	var projectActivityID sql.NullInt64
	if err := s.db.QueryRowContext(ctx, `SELECT project_activity_id FROM mapping_rules WHERE rule_key = 'rule.composite'`).Scan(&projectActivityID); err != nil {
		t.Fatalf("query mapping rule failed: %v", err)
	}
	if !projectActivityID.Valid || projectActivityID.Int64 <= 0 {
		t.Fatalf("expected project_activity_id to be stored, got %+v", projectActivityID)
	}
}

func TestRemoveActivityFromProjectKeepsSharedActivityForOtherProjects(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	ctx := context.Background()

	if _, err := s.db.ExecContext(ctx, `INSERT INTO customers (customer_id, name) VALUES (1, 'internal')`); err != nil {
		t.Fatalf("seed customer failed: %v", err)
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO projects (project_id, customer_id, name, title, metadata) VALUES (10, 1, 'web-app', 'web-app', '')`); err != nil {
		t.Fatalf("seed project 10 failed: %v", err)
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO projects (project_id, customer_id, name, title, metadata) VALUES (11, 1, 'api', 'api', '')`); err != nil {
		t.Fatalf("seed project 11 failed: %v", err)
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO activities (activity_id, project_id, name, title) VALUES (100, 0, 'development', 'development')`); err != nil {
		t.Fatalf("seed shared activity failed: %v", err)
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO project_activities (project_id, activity_id) VALUES (10, 100)`); err != nil {
		t.Fatalf("seed link 10->100 failed: %v", err)
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO project_activities (project_id, activity_id) VALUES (11, 100)`); err != nil {
		t.Fatalf("seed link 11->100 failed: %v", err)
	}

	if err := s.RemoveActivityFromProject(ctx, 10, 100); err != nil {
		t.Fatalf("remove activity from project failed: %v", err)
	}

	activities, err := s.ListActivitiesByProject(ctx, 10)
	if err != nil {
		t.Fatalf("list project 10 activities failed: %v", err)
	}
	if len(activities) != 0 {
		t.Fatalf("expected no activities for project 10, got %+v", activities)
	}

	activities, err = s.ListActivitiesByProject(ctx, 11)
	if err != nil {
		t.Fatalf("list project 11 activities failed: %v", err)
	}
	if len(activities) != 1 || activities[0].ActivityID != 100 {
		t.Fatalf("expected shared activity to remain for project 11, got %+v", activities)
	}
}

func TestCreateArchiveRestoreProjectLifecycle(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	ctx := context.Background()

	project, err := s.CreateProject(ctx, "Portal", "customer-facing app")
	if err != nil {
		t.Fatalf("create project failed: %v", err)
	}
	if project.Title != "Portal" {
		t.Fatalf("expected Portal title, got %q", project.Title)
	}

	allProjects, err := s.ListAllProjects(ctx)
	if err != nil {
		t.Fatalf("list all projects failed: %v", err)
	}
	foundPortal := false
	for _, item := range allProjects {
		if item.ProjectID == project.ProjectID {
			foundPortal = true
			break
		}
	}
	if !foundPortal {
		t.Fatalf("expected created project in active list")
	}

	if err := s.ArchiveProject(ctx, project.ProjectID); err != nil {
		t.Fatalf("archive project failed: %v", err)
	}
	allProjects, err = s.ListAllProjects(ctx)
	if err != nil {
		t.Fatalf("list all projects after archive failed: %v", err)
	}
	for _, item := range allProjects {
		if item.ProjectID == project.ProjectID {
			t.Fatalf("expected archived project to be hidden from active list")
		}
	}
	archivedProjects, err := s.ListArchivedProjects(ctx)
	if err != nil {
		t.Fatalf("list archived projects failed: %v", err)
	}
	foundArchived := false
	for _, item := range archivedProjects {
		if item.ProjectID == project.ProjectID {
			foundArchived = true
			break
		}
	}
	if !foundArchived {
		t.Fatalf("expected project in archived list")
	}

	if err := s.RestoreProject(ctx, project.ProjectID); err != nil {
		t.Fatalf("restore project failed: %v", err)
	}
	allProjects, err = s.ListAllProjects(ctx)
	if err != nil {
		t.Fatalf("list all projects after restore failed: %v", err)
	}
	foundRestored := false
	for _, item := range allProjects {
		if item.ProjectID == project.ProjectID {
			foundRestored = true
			break
		}
	}
	if !foundRestored {
		t.Fatalf("expected restored project in active list")
	}
}

func TestAddActivityRejectsDuplicates(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	ctx := context.Background()
	seedProjectActivity(t, s)

	_, err := s.AddActivity(ctx, 10, "planning")
	if err != nil {
		t.Fatalf("first add activity failed: %v", err)
	}
	_, err = s.AddActivity(ctx, 10, " Planning ")
	if !errors.Is(err, domain.ErrActivityTitleConflict) {
		t.Fatalf("expected duplicate activity error, got %v", err)
	}
}

func TestDeleteActivityGuardWhenReferencedByRule(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	ctx := context.Background()
	seedProjectActivity(t, s)

	if _, err := s.db.ExecContext(ctx, `INSERT INTO mapping_rules (activity_id) VALUES (100)`); err != nil {
		t.Fatalf("insert mapping rule failed: %v", err)
	}
	err := s.DeleteActivity(ctx, 100)
	if !errors.Is(err, domain.ErrActivityInUse) {
		t.Fatalf("expected in-use error, got %v", err)
	}
}

func TestDeleteActivityGuardWhenReferencedByEvents(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	ctx := context.Background()
	seedProjectActivity(t, s)

	if _, err := s.db.ExecContext(ctx, `
INSERT INTO events (timestamp_ms, app_name, window_title, duration_ms, project_id, activity_id, manually_mapped)
VALUES (1, 'Code', 'main.go', 60000, 10, 101, true)
`); err != nil {
		t.Fatalf("insert mapped event failed: %v", err)
	}
	err := s.DeleteActivity(ctx, 101)
	if !errors.Is(err, domain.ErrActivityInUse) {
		t.Fatalf("expected in-use error, got %v", err)
	}
}

func TestUpsertImportedProjectCreatesAndUpdates(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	ctx := context.Background()

	first, err := s.UpsertImportedProject(ctx, domain.ImportedProjectUpsert{
		Source:             "tidsreg",
		ExternalCustomerID: 1,
		ExternalProjectID:  10,
		ExternalVariantKey: "1:10:100",
		Title:              "A > B > C",
		Metadata:           "meta1",
	})
	if err != nil {
		t.Fatalf("upsert create failed: %v", err)
	}
	if !first.Created || first.ProjectID <= 0 {
		t.Fatalf("expected created project, got %+v", first)
	}

	second, err := s.UpsertImportedProject(ctx, domain.ImportedProjectUpsert{
		Source:             "tidsreg",
		ExternalCustomerID: 1,
		ExternalProjectID:  10,
		ExternalVariantKey: "1:10:100",
		Title:              "A > B > C updated",
		Metadata:           "meta2",
	})
	if err != nil {
		t.Fatalf("upsert update failed: %v", err)
	}
	if second.Created || !second.Updated || second.ProjectID != first.ProjectID {
		t.Fatalf("expected update on same project, got %+v", second)
	}
}

func TestUpsertImportedProjectMatchesLegacyRowWithoutVariantKey(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	ctx := context.Background()

	if _, err := s.db.ExecContext(ctx, `
INSERT INTO projects (
	project_id, customer_id, name, title, metadata, source, external_customer_id, external_project_id, external_phase_id
) VALUES (77, 0, 'Legacy', 'Legacy', 'legacy-meta', 'tidsreg', 1, 10, 100)
`); err != nil {
		t.Fatalf("insert legacy project failed: %v", err)
	}

	result, err := s.UpsertImportedProject(ctx, domain.ImportedProjectUpsert{
		Source:             "tidsreg",
		ExternalCustomerID: 1,
		ExternalProjectID:  10,
		ExternalVariantKey: "1:10:100",
		Title:              "Legacy Updated",
		Metadata:           "meta-updated",
	})
	if err != nil {
		t.Fatalf("upsert legacy match failed: %v", err)
	}
	if result.Created || !result.Updated || result.ProjectID != 77 {
		t.Fatalf("expected existing legacy row to be updated, got %+v", result)
	}
}

func TestSyncImportedActivitiesReconcilesRows(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	ctx := context.Background()

	project, err := s.UpsertImportedProject(ctx, domain.ImportedProjectUpsert{
		Source:             "tidsreg",
		ExternalCustomerID: 7,
		ExternalProjectID:  8,
		ExternalVariantKey: "7:8:9",
		Title:              "Cust > Proj > Variant",
		Metadata:           "meta",
	})
	if err != nil {
		t.Fatalf("upsert project failed: %v", err)
	}

	first, err := s.SyncImportedActivities(ctx, project.ProjectID, []domain.ImportedActivityUpsert{
		{Source: "tidsreg", ExternalActivityID: 1000, Title: "Coding"},
		{Source: "tidsreg", ExternalActivityID: 1001, Title: "Meeting"},
	})
	if err != nil {
		t.Fatalf("sync first failed: %v", err)
	}
	if first.Created != 2 || first.Updated != 0 || first.Deleted != 0 {
		t.Fatalf("unexpected first sync result: %+v", first)
	}

	second, err := s.SyncImportedActivities(ctx, project.ProjectID, []domain.ImportedActivityUpsert{
		{Source: "tidsreg", ExternalActivityID: 1000, Title: "Coding Updated"},
	})
	if err != nil {
		t.Fatalf("sync second failed: %v", err)
	}
	if second.Updated != 1 || second.Deleted != 1 {
		t.Fatalf("unexpected second sync result: %+v", second)
	}
}

func TestListReportEventsFiltersByDate(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	ctx := context.Background()

	ts1 := time.Date(2026, time.February, 6, 12, 0, 0, 0, time.Local).UnixMilli()
	ts2 := time.Date(2026, time.February, 7, 12, 0, 0, 0, time.Local).UnixMilli()
	if _, err := s.db.ExecContext(ctx, `INSERT INTO events (id, timestamp_ms, app_name, window_title, duration_ms, manually_mapped) VALUES (1, ?, 'Code', 'a', 60000, false)`, ts1); err != nil {
		t.Fatalf("insert first event: %v", err)
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO events (id, timestamp_ms, app_name, window_title, duration_ms, manually_mapped) VALUES (2, ?, 'Code', 'b', 60000, false)`, ts2); err != nil {
		t.Fatalf("insert second event: %v", err)
	}

	date := "2026-02-06"
	events, err := s.ListReportEvents(ctx, "all", &date)
	if err != nil {
		t.Fatalf("list report events by date: %v", err)
	}
	if len(events) != 1 {
		t.Fatalf("expected 1 event for date filter, got %d", len(events))
	}
	if events[0].ID != 1 {
		t.Fatalf("expected event id 1, got %d", events[0].ID)
	}
}

func TestListReportEventsDateTakesPrecedenceOverRange(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	ctx := context.Background()

	ts1 := time.Date(2026, time.February, 6, 12, 0, 0, 0, time.Local).UnixMilli()
	if _, err := s.db.ExecContext(ctx, `INSERT INTO events (id, timestamp_ms, app_name, window_title, duration_ms, manually_mapped) VALUES (10, ?, 'Code', 'a', 60000, false)`, ts1); err != nil {
		t.Fatalf("insert event: %v", err)
	}

	date := "2026-02-06"
	events, err := s.ListReportEvents(ctx, "today", &date)
	if err != nil {
		t.Fatalf("list report events with range+date: %v", err)
	}
	if len(events) != 1 || events[0].ID != 10 {
		t.Fatalf("expected date to take precedence over range, got %+v", events)
	}
}

func TestListGroupedUnmappedEventsIncludesWifiSummary(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	ctx := context.Background()

	ts := time.Date(2026, time.February, 6, 12, 0, 0, 0, time.Local).UnixMilli()
	if _, err := s.db.ExecContext(ctx, `INSERT INTO events (id, timestamp_ms, app_name, window_title, wifi_ssid, duration_ms, manually_mapped) VALUES (100, ?, 'Code', 'main.go', 'Office', 60000, false)`, ts); err != nil {
		t.Fatalf("insert first event: %v", err)
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO events (id, timestamp_ms, app_name, window_title, wifi_ssid, duration_ms, manually_mapped) VALUES (101, ?, 'Code', 'main.go', 'Home', 30000, false)`, ts+1); err != nil {
		t.Fatalf("insert second event: %v", err)
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO events (id, timestamp_ms, app_name, window_title, wifi_ssid, duration_ms, manually_mapped) VALUES (102, ?, 'Slack', 'chat', '', 20000, false)`, ts+2); err != nil {
		t.Fatalf("insert third event: %v", err)
	}

	groups, err := s.ListGroupedUnmappedEvents(ctx, "2026-02-06", 0)
	if err != nil {
		t.Fatalf("list grouped unmapped events: %v", err)
	}
	if len(groups) != 2 {
		t.Fatalf("expected 2 groups, got %d", len(groups))
	}

	var codeGroup *domain.GroupedEvent
	var slackGroup *domain.GroupedEvent
	for i := range groups {
		g := &groups[i]
		if g.AppName == "Code" && g.WindowTitle == "main.go" {
			codeGroup = g
		}
		if g.AppName == "Slack" && g.WindowTitle == "chat" {
			slackGroup = g
		}
	}

	if codeGroup == nil {
		t.Fatalf("expected Code/main.go group")
	}
	if codeGroup.WifiSSID != "(multiple)" {
		t.Fatalf("expected code group wifi summary '(multiple)', got %q", codeGroup.WifiSSID)
	}
	if codeGroup.EventCount != 2 || codeGroup.TotalDurationMS != 90_000 {
		t.Fatalf("unexpected code group stats: %+v", *codeGroup)
	}

	if slackGroup == nil {
		t.Fatalf("expected Slack/chat group")
	}
	if slackGroup.WifiSSID != "(none)" {
		t.Fatalf("expected slack group wifi summary '(none)', got %q", slackGroup.WifiSSID)
	}
}

func TestConvertLegacyGlobRules(t *testing.T) {
	s := openTestStore(t)
	defer s.Close()
	ctx := context.Background()

	if _, err := s.db.ExecContext(ctx, `
INSERT INTO mapping_rules (
	id, priority, app_pattern, title_pattern, pattern_format, action_type, source
) VALUES (1, 10, '*Chrome*', '*project-a*', 'glob', 'assign_explicit', 'user')
`); err != nil {
		t.Fatalf("insert legacy rule: %v", err)
	}

	if err := s.convertLegacyGlobRules(ctx); err != nil {
		t.Fatalf("convert legacy rules: %v", err)
	}

	var appPattern, titlePattern, patternFormat string
	if err := s.db.QueryRowContext(ctx, `SELECT app_pattern, title_pattern, pattern_format FROM mapping_rules WHERE id = 1`).Scan(&appPattern, &titlePattern, &patternFormat); err != nil {
		t.Fatalf("query converted rule: %v", err)
	}
	if appPattern != "(?i)^.*Chrome.*$" {
		t.Fatalf("unexpected converted app pattern: %s", appPattern)
	}
	if titlePattern != "(?i)^.*project-a.*$" {
		t.Fatalf("unexpected converted title pattern: %s", titlePattern)
	}
	if patternFormat != "regex" {
		t.Fatalf("expected pattern_format regex, got %s", patternFormat)
	}
}
