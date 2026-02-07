package duckdb

import (
	"context"
	"database/sql"
	"path/filepath"
	"reflect"
	"testing"
)

func seedLegacyVersion9Schema(t *testing.T, db *sql.DB, kindsStmt, kindsNewStmt string) {
	t.Helper()

	setup := []string{
		`CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, name VARCHAR NOT NULL, applied_at TIMESTAMP DEFAULT current_timestamp);`,
		`INSERT INTO schema_migrations (version, name) VALUES (9, 'add_follow_previous_rules');`,
		`CREATE TABLE events (id INTEGER PRIMARY KEY, timestamp_ms BIGINT, app_name VARCHAR, window_title VARCHAR, duration_ms BIGINT, activity_id INTEGER, kind_id INTEGER, manually_mapped BOOLEAN);`,
		`CREATE TABLE customers (customer_id INTEGER PRIMARY KEY, name VARCHAR);`,
		`CREATE TABLE projects (project_id INTEGER PRIMARY KEY, customer_id INTEGER, name VARCHAR);`,
		`CREATE TABLE phases (phase_id INTEGER PRIMARY KEY, project_id INTEGER, name VARCHAR);`,
		`CREATE TABLE activities (activity_id INTEGER PRIMARY KEY, phase_id INTEGER, name VARCHAR);`,
		kindsStmt,
		kindsNewStmt,
		`CREATE TABLE mapping_rules (id INTEGER PRIMARY KEY, priority INTEGER, app_pattern VARCHAR, title_pattern VARCHAR, activity_id INTEGER, kind_id INTEGER, follow_previous BOOLEAN);`,
		`CREATE TABLE project_assignments (id INTEGER PRIMARY KEY, project_id INTEGER, started_at TIMESTAMP, ended_at TIMESTAMP);`,
	}
	for _, stmt := range setup {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("setup failed (%s): %v", stmt, err)
		}
	}
}

func assertSimplifiedProjectSchema(t *testing.T, db *sql.DB) {
	t.Helper()

	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM projects`).Scan(&count); err != nil {
		t.Fatalf("query projects failed: %v", err)
	}
	if count < 1 {
		t.Fatalf("expected at least one project row after migration bootstrap, got %d", count)
	}

	var titleColumnCount int
	if err := db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('projects') WHERE name = 'title'`).Scan(&titleColumnCount); err != nil {
		t.Fatalf("inspect projects schema failed: %v", err)
	}
	if titleColumnCount != 1 {
		t.Fatalf("expected projects.title column after migration")
	}

	var variantColumnCount int
	if err := db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('projects') WHERE name = 'external_variant_key'`).Scan(&variantColumnCount); err != nil {
		t.Fatalf("inspect projects external_variant_key column failed: %v", err)
	}
	if variantColumnCount != 1 {
		t.Fatalf("expected projects.external_variant_key column after migration")
	}

	var externalPhaseColumnCount int
	if err := db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('projects') WHERE name = 'external_phase_id'`).Scan(&externalPhaseColumnCount); err != nil {
		t.Fatalf("inspect projects external_phase_id column failed: %v", err)
	}
	if externalPhaseColumnCount != 1 {
		t.Fatalf("expected projects.external_phase_id column to remain for compatibility")
	}

	var activityPhaseColumnCount int
	if err := db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('activities') WHERE name = 'phase_id'`).Scan(&activityPhaseColumnCount); err != nil {
		t.Fatalf("inspect activities.phase_id failed: %v", err)
	}
	if activityPhaseColumnCount != 0 {
		t.Fatalf("expected activities.phase_id to be removed after migration")
	}

	var phasesTableCount int
	if err := db.QueryRow(`SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'phases'`).Scan(&phasesTableCount); err != nil {
		t.Fatalf("inspect phases table failed: %v", err)
	}
	if phasesTableCount != 0 {
		t.Fatalf("expected phases table to be removed after migration")
	}
}

func assertRuleCompatibilitySchema(t *testing.T, db *sql.DB) {
	t.Helper()

	for _, col := range []string{"kind_id", "is_global", "kind_name"} {
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('mapping_rules') WHERE name = ?`, col).Scan(&n); err != nil {
			t.Fatalf("inspect mapping_rules.%s failed: %v", col, err)
		}
		if n != 1 {
			t.Fatalf("expected mapping_rules.%s column after migration", col)
		}
	}

	var kindsOK int
	if err := db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('kinds')`).Scan(&kindsOK); err != nil {
		t.Fatalf("inspect kinds table failed: %v", err)
	}
}

func TestMigrateHandlesLegacyKindsNewDependencyAtVersion9(t *testing.T) {
	db, err := sql.Open("duckdb", ":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()

	seedLegacyVersion9Schema(
		t,
		db,
		`CREATE TABLE kinds (kind_id INTEGER PRIMARY KEY, activity_id INTEGER, name VARCHAR, billable BOOLEAN);`,
		`CREATE TABLE kinds_new (activity_id INTEGER NOT NULL REFERENCES activities(activity_id), kind_id INTEGER NOT NULL, name VARCHAR, billable BOOLEAN, PRIMARY KEY (activity_id, kind_id));`,
	)

	if err := migrate(db); err != nil {
		t.Fatalf("migrate failed: %v", err)
	}

	assertSimplifiedProjectSchema(t, db)
	assertRuleCompatibilitySchema(t, db)

	var sourceColumnCount int
	if err := db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('projects') WHERE name = 'source'`).Scan(&sourceColumnCount); err != nil {
		t.Fatalf("inspect projects source column failed: %v", err)
	}
	if sourceColumnCount != 1 {
		t.Fatalf("expected projects.source column after migration")
	}
}

func TestMigrateHandlesLegacyKindsNewReferencingKinds(t *testing.T) {
	db, err := sql.Open("duckdb", ":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()

	seedLegacyVersion9Schema(
		t,
		db,
		`CREATE TABLE kinds (kind_id INTEGER PRIMARY KEY, activity_id INTEGER, name VARCHAR, billable BOOLEAN);`,
		`CREATE TABLE kinds_new (kind_id INTEGER NOT NULL REFERENCES kinds(kind_id), activity_id INTEGER NOT NULL, name VARCHAR, billable BOOLEAN, PRIMARY KEY (activity_id, kind_id));`,
	)

	if err := migrate(db); err != nil {
		t.Fatalf("migrate failed: %v", err)
	}

	assertSimplifiedProjectSchema(t, db)
	assertRuleCompatibilitySchema(t, db)
}

func TestOpenMigratesLegacyVersion9DatabaseFromDisk(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "tracker.db")

	db, err := sql.Open("duckdb", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	seedLegacyVersion9Schema(
		t,
		db,
		`CREATE TABLE kinds (kind_id INTEGER PRIMARY KEY, activity_id INTEGER, name VARCHAR, billable BOOLEAN);`,
		`CREATE TABLE kinds_new (kind_id INTEGER NOT NULL REFERENCES kinds(kind_id), activity_id INTEGER NOT NULL, name VARCHAR, billable BOOLEAN, PRIMARY KEY (activity_id, kind_id));`,
	)
	if err := db.Close(); err != nil {
		t.Fatalf("close setup db: %v", err)
	}

	store, err := Open(dbPath)
	if err != nil {
		t.Fatalf("open store failed: %v", err)
	}
	defer func() { _ = store.Close() }()

	rules, err := store.ListRules(context.Background())
	if err != nil {
		t.Fatalf("list rules failed: %v", err)
	}
	if len(rules) != 0 {
		t.Fatalf("expected no rules in fresh simplified schema, got %d", len(rules))
	}

	var version int
	if err := store.db.QueryRow(`SELECT COALESCE(MAX(version), 0) FROM schema_migrations`).Scan(&version); err != nil {
		t.Fatalf("query schema_migrations failed: %v", err)
	}
	if version != 13 {
		t.Fatalf("expected schema version 13, got %d", version)
	}
}

func TestMigrateHandlesVersion12WithoutKindsTable(t *testing.T) {
	db, err := sql.Open("duckdb", ":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()

	setup := []string{
		`CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, name VARCHAR NOT NULL, applied_at TIMESTAMP DEFAULT current_timestamp);`,
		`INSERT INTO schema_migrations (version, name) VALUES (12, 'add_tidsreg_import_columns');`,
		`CREATE TABLE customers (customer_id INTEGER PRIMARY KEY, name VARCHAR);`,
		`CREATE TABLE projects (project_id INTEGER PRIMARY KEY, customer_id INTEGER, name VARCHAR, title VARCHAR, metadata VARCHAR, source VARCHAR, external_customer_id BIGINT, external_project_id BIGINT, external_phase_id BIGINT);`,
		`CREATE UNIQUE INDEX projects_source_external_idx ON projects (source, external_customer_id, external_project_id, external_phase_id);`,
		`CREATE TABLE phases (phase_id INTEGER PRIMARY KEY, project_id INTEGER, name VARCHAR);`,
		`CREATE TABLE activities (activity_id INTEGER PRIMARY KEY, phase_id INTEGER, project_id INTEGER, name VARCHAR, title VARCHAR, source VARCHAR, external_activity_id BIGINT);`,
		`CREATE TABLE mapping_rules (id INTEGER PRIMARY KEY, priority INTEGER, app_pattern VARCHAR, title_pattern VARCHAR, project_id INTEGER, activity_id INTEGER, kind_id INTEGER, is_global BOOLEAN, kind_name VARCHAR, follow_previous BOOLEAN, created_at TIMESTAMP, rule_key VARCHAR, source VARCHAR, action_type VARCHAR, action_project_title VARCHAR, action_activity_title VARCHAR, pattern_format VARCHAR);`,
		`INSERT INTO customers (customer_id, name) VALUES (1, 'Acme');`,
		`INSERT INTO projects (project_id, customer_id, name, title, metadata, source, external_customer_id, external_project_id, external_phase_id) VALUES (10, 1, 'P', 'P', '', 'tidsreg', 1, 2, 3);`,
		`INSERT INTO phases (phase_id, project_id, name) VALUES (20, 10, 'Legacy');`,
		`INSERT INTO activities (activity_id, phase_id, project_id, name, title, source, external_activity_id) VALUES (30, 20, 10, 'A', 'A', 'tidsreg', 99);`,
	}
	for _, stmt := range setup {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("setup failed (%s): %v", stmt, err)
		}
	}

	if err := migrate(db); err != nil {
		t.Fatalf("migrate failed: %v", err)
	}

	var version int
	if err := db.QueryRow(`SELECT COALESCE(MAX(version), 0) FROM schema_migrations`).Scan(&version); err != nil {
		t.Fatalf("query schema_migrations failed: %v", err)
	}
	if version != 13 {
		t.Fatalf("expected schema version 13, got %d", version)
	}

	var phasesCount int
	if err := db.QueryRow(`SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'phases'`).Scan(&phasesCount); err != nil {
		t.Fatalf("inspect phases table failed: %v", err)
	}
	if phasesCount != 0 {
		t.Fatalf("expected phases table to be removed")
	}

	var kindsCount int
	if err := db.QueryRow(`SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'kinds'`).Scan(&kindsCount); err != nil {
		t.Fatalf("inspect kinds table failed: %v", err)
	}
	if kindsCount != 1 {
		t.Fatalf("expected kinds table to be recreated")
	}
}

func TestSplitSQLStatementsSkipsCommentsAndEmpties(t *testing.T) {
	sqlText := `
-- comment
CREATE TABLE a (id INTEGER);

  -- another comment
INSERT INTO a VALUES (1);
`
	got := splitSQLStatements(sqlText)
	want := []string{
		"CREATE TABLE a (id INTEGER);",
		"INSERT INTO a VALUES (1);",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("unexpected statements: got=%v want=%v", got, want)
	}
}
