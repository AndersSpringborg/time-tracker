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
