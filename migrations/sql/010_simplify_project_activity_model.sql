ALTER TABLE events ADD COLUMN IF NOT EXISTS project_id INTEGER;
UPDATE events SET project_id = NULL, activity_id = NULL, manually_mapped = false;

DROP TABLE IF EXISTS project_assignments CASCADE;
DROP TABLE IF EXISTS mapping_rules CASCADE;
DROP TABLE IF EXISTS kinds_new CASCADE;
DROP TABLE IF EXISTS kinds CASCADE;

-- Transform hierarchy tables in place to avoid brittle DROP behavior on
-- legacy FK variants (e.g. kinds_new depending on kinds or activities).
CREATE SEQUENCE IF NOT EXISTS projects_seq;
CREATE TABLE IF NOT EXISTS projects (
    project_id INTEGER PRIMARY KEY DEFAULT nextval('projects_seq'),
    title VARCHAR NOT NULL,
    metadata VARCHAR NOT NULL DEFAULT ''
);
ALTER TABLE projects ADD COLUMN IF NOT EXISTS title VARCHAR;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS metadata VARCHAR;
UPDATE projects SET title = COALESCE(title, name, '');
UPDATE projects SET metadata = COALESCE(metadata, '');

CREATE SEQUENCE IF NOT EXISTS activities_seq;
CREATE TABLE IF NOT EXISTS activities (
    activity_id INTEGER PRIMARY KEY DEFAULT nextval('activities_seq'),
    project_id INTEGER NOT NULL REFERENCES projects(project_id),
    title VARCHAR NOT NULL
);
ALTER TABLE activities ADD COLUMN IF NOT EXISTS project_id INTEGER;
ALTER TABLE activities ADD COLUMN IF NOT EXISTS title VARCHAR;
UPDATE activities AS a
SET project_id = p.project_id
FROM phases AS p
WHERE a.project_id IS NULL
  AND a.phase_id = p.phase_id;
UPDATE activities SET title = COALESCE(title, name, '');

CREATE SEQUENCE IF NOT EXISTS kinds_seq;
CREATE TABLE IF NOT EXISTS kinds (
    kind_id INTEGER PRIMARY KEY DEFAULT nextval('kinds_seq'),
    activity_id INTEGER NOT NULL REFERENCES activities(activity_id),
    name VARCHAR NOT NULL,
    billable BOOLEAN NOT NULL DEFAULT true
);

INSERT INTO customers (customer_id, name)
SELECT 0, 'Legacy'
WHERE NOT EXISTS (SELECT 1 FROM customers WHERE customer_id = 0);
INSERT INTO projects (project_id, customer_id, name, title, metadata)
SELECT 0, 0, 'Legacy', 'Legacy', ''
WHERE NOT EXISTS (SELECT 1 FROM projects WHERE project_id = 0);
INSERT INTO phases (phase_id, project_id, name)
SELECT 0, 0, 'Legacy'
WHERE NOT EXISTS (SELECT 1 FROM phases WHERE phase_id = 0);

CREATE SEQUENCE IF NOT EXISTS mapping_rules_seq;
CREATE TABLE IF NOT EXISTS mapping_rules (
    id INTEGER PRIMARY KEY DEFAULT nextval('mapping_rules_seq'),
    priority INTEGER NOT NULL DEFAULT 0,
    app_pattern VARCHAR,
    title_pattern VARCHAR,
    project_id INTEGER REFERENCES projects(project_id),
    activity_id INTEGER,
    kind_id INTEGER,
    is_global BOOLEAN NOT NULL DEFAULT false,
    kind_name VARCHAR,
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
