package duckdb

import (
	"database/sql"
	"fmt"
)

type migration struct {
	version int
	name    string
	upSQL   string
}

var migrations = []migration{
	{1, "create_events_table", `
CREATE SEQUENCE IF NOT EXISTS events_seq;
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY DEFAULT nextval('events_seq'),
    timestamp_ms BIGINT NOT NULL,
    app_name VARCHAR NOT NULL,
    window_title VARCHAR NOT NULL,
    duration_ms BIGINT NOT NULL,
    created_at TIMESTAMP DEFAULT current_timestamp
);
`},
	{2, "add_wifi_ssid", `ALTER TABLE events ADD COLUMN IF NOT EXISTS wifi_ssid VARCHAR DEFAULT '';`},
	{3, "create_hierarchy_tables", `
CREATE TABLE IF NOT EXISTS customers (
    customer_id INTEGER PRIMARY KEY,
    name VARCHAR NOT NULL
);
CREATE TABLE IF NOT EXISTS projects (
    project_id INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(customer_id),
    name VARCHAR NOT NULL
);
CREATE TABLE IF NOT EXISTS phases (
    phase_id INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES projects(project_id),
    name VARCHAR NOT NULL
);
CREATE TABLE IF NOT EXISTS activities (
    activity_id INTEGER PRIMARY KEY,
    phase_id INTEGER NOT NULL REFERENCES phases(phase_id),
    name VARCHAR NOT NULL
);
CREATE TABLE IF NOT EXISTS kinds (
    kind_id INTEGER PRIMARY KEY,
    activity_id INTEGER NOT NULL REFERENCES activities(activity_id),
    name VARCHAR NOT NULL,
    billable BOOLEAN NOT NULL DEFAULT true
);
`},
	{4, "create_mapping_rules", `
CREATE SEQUENCE IF NOT EXISTS mapping_rules_seq;
CREATE TABLE IF NOT EXISTS mapping_rules (
    id INTEGER PRIMARY KEY DEFAULT nextval('mapping_rules_seq'),
    priority INTEGER NOT NULL DEFAULT 0,
    app_pattern VARCHAR,
    title_pattern VARCHAR,
    activity_id INTEGER,
    kind_id INTEGER,
    created_at TIMESTAMP DEFAULT current_timestamp
);
`},
	{5, "add_event_mapping_columns", `
ALTER TABLE events ADD COLUMN IF NOT EXISTS activity_id INTEGER;
ALTER TABLE events ADD COLUMN IF NOT EXISTS kind_id INTEGER;
ALTER TABLE events ADD COLUMN IF NOT EXISTS manually_mapped BOOLEAN DEFAULT false;
`},
	{6, "create_project_assignments", `
CREATE SEQUENCE IF NOT EXISTS project_assignments_seq;
CREATE TABLE IF NOT EXISTS project_assignments (
    id INTEGER PRIMARY KEY DEFAULT nextval('project_assignments_seq'),
    project_id INTEGER NOT NULL REFERENCES projects(project_id),
    started_at TIMESTAMP DEFAULT current_timestamp,
    ended_at TIMESTAMP,
    UNIQUE(project_id, started_at)
);
`},
	{7, "add_global_rules_support", `
ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS is_global BOOLEAN DEFAULT false;
ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS kind_name VARCHAR;
`},
	{8, "fix_kinds_composite_primary_key", `
SELECT 1;
`},
	{9, "add_follow_previous_rules", `ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS follow_previous BOOLEAN DEFAULT false;`},
	{10, "simplify_project_activity_model", `
ALTER TABLE events ADD COLUMN IF NOT EXISTS project_id INTEGER;
UPDATE events SET project_id = NULL, activity_id = NULL, manually_mapped = false;

DROP TABLE IF EXISTS project_assignments CASCADE;
DROP TABLE IF EXISTS mapping_rules CASCADE;
DROP TABLE IF EXISTS kinds CASCADE;
DROP TABLE IF EXISTS kinds_new CASCADE;
DROP TABLE IF EXISTS activities CASCADE;
DROP TABLE IF EXISTS phases CASCADE;
DROP TABLE IF EXISTS projects CASCADE;
DROP TABLE IF EXISTS customers CASCADE;

CREATE SEQUENCE IF NOT EXISTS projects_seq;
CREATE TABLE IF NOT EXISTS projects (
    project_id INTEGER PRIMARY KEY DEFAULT nextval('projects_seq'),
    title VARCHAR NOT NULL,
    metadata VARCHAR NOT NULL DEFAULT ''
);

CREATE SEQUENCE IF NOT EXISTS activities_seq;
CREATE TABLE IF NOT EXISTS activities (
    activity_id INTEGER PRIMARY KEY DEFAULT nextval('activities_seq'),
    project_id INTEGER NOT NULL REFERENCES projects(project_id),
    title VARCHAR NOT NULL
);

CREATE SEQUENCE IF NOT EXISTS mapping_rules_seq;
CREATE TABLE IF NOT EXISTS mapping_rules (
    id INTEGER PRIMARY KEY DEFAULT nextval('mapping_rules_seq'),
    priority INTEGER NOT NULL DEFAULT 0,
    app_pattern VARCHAR,
    title_pattern VARCHAR,
    project_id INTEGER REFERENCES projects(project_id),
    activity_id INTEGER REFERENCES activities(activity_id),
    follow_previous BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMP DEFAULT current_timestamp
);

CREATE SEQUENCE IF NOT EXISTS project_assignments_seq;
CREATE TABLE IF NOT EXISTS project_assignments (
    id INTEGER PRIMARY KEY DEFAULT nextval('project_assignments_seq'),
    project_id INTEGER NOT NULL REFERENCES projects(project_id),
    started_at TIMESTAMP DEFAULT current_timestamp,
    ended_at TIMESTAMP,
    UNIQUE(project_id, started_at)
);
`},
}

func migrate(db *sql.DB) error {
	if _, err := db.Exec(`
CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    name VARCHAR NOT NULL,
    applied_at TIMESTAMP DEFAULT current_timestamp
);
`); err != nil {
		return fmt.Errorf("create schema_migrations: %w", err)
	}

	currentVersion := 0
	if err := db.QueryRow(`SELECT COALESCE(MAX(version), 0) FROM schema_migrations`).Scan(&currentVersion); err != nil {
		return fmt.Errorf("read schema_migrations: %w", err)
	}

	for _, m := range migrations {
		if m.version <= currentVersion {
			continue
		}
		if _, err := db.Exec(m.upSQL); err != nil {
			return fmt.Errorf("apply migration %d (%s): %w", m.version, m.name, err)
		}
		if _, err := db.Exec(`INSERT INTO schema_migrations (version, name) VALUES (?, ?)`, m.version, m.name); err != nil {
			return fmt.Errorf("record migration %d: %w", m.version, err)
		}
	}

	return nil
}
