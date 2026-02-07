package duckdb

import (
	"database/sql"
	"testing"
)

func TestMigrateHandlesLegacyKindsNewDependencyAtVersion9(t *testing.T) {
	db, err := sql.Open("duckdb", ":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()

	setup := []string{
		`CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, name VARCHAR NOT NULL, applied_at TIMESTAMP DEFAULT current_timestamp);`,
		`INSERT INTO schema_migrations (version, name) VALUES (9, 'add_follow_previous_rules');`,
		`CREATE TABLE events (id INTEGER PRIMARY KEY, timestamp_ms BIGINT, app_name VARCHAR, window_title VARCHAR, duration_ms BIGINT, activity_id INTEGER, kind_id INTEGER, manually_mapped BOOLEAN);`,
		`CREATE TABLE customers (customer_id INTEGER PRIMARY KEY, name VARCHAR);`,
		`CREATE TABLE projects (project_id INTEGER PRIMARY KEY, customer_id INTEGER, name VARCHAR);`,
		`CREATE TABLE phases (phase_id INTEGER PRIMARY KEY, project_id INTEGER, name VARCHAR);`,
		`CREATE TABLE activities (activity_id INTEGER PRIMARY KEY, phase_id INTEGER, name VARCHAR);`,
		`CREATE TABLE kinds_new (activity_id INTEGER NOT NULL REFERENCES activities(activity_id), kind_id INTEGER NOT NULL, name VARCHAR, billable BOOLEAN, PRIMARY KEY (activity_id, kind_id));`,
		`CREATE TABLE mapping_rules (id INTEGER PRIMARY KEY, priority INTEGER, app_pattern VARCHAR, title_pattern VARCHAR, activity_id INTEGER, kind_id INTEGER, follow_previous BOOLEAN);`,
		`CREATE TABLE project_assignments (id INTEGER PRIMARY KEY, project_id INTEGER, started_at TIMESTAMP, ended_at TIMESTAMP);`,
	}
	for _, stmt := range setup {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("setup failed (%s): %v", stmt, err)
		}
	}

	if err := migrate(db); err != nil {
		t.Fatalf("migrate failed: %v", err)
	}

	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM projects`).Scan(&count); err != nil {
		t.Fatalf("query projects failed: %v", err)
	}
	if count != 0 {
		t.Fatalf("expected empty projects after migration, got %d", count)
	}

	var titleColumnCount int
	if err := db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('projects') WHERE name = 'title'`).Scan(&titleColumnCount); err != nil {
		t.Fatalf("inspect projects schema failed: %v", err)
	}
	if titleColumnCount != 1 {
		t.Fatalf("expected projects.title column after migration")
	}

	var sourceColumnCount int
	if err := db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('projects') WHERE name = 'source'`).Scan(&sourceColumnCount); err != nil {
		t.Fatalf("inspect projects source column failed: %v", err)
	}
	if sourceColumnCount != 1 {
		t.Fatalf("expected projects.source column after migration")
	}
}
