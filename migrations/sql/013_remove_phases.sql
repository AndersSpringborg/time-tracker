-- Remove phase entities from the schema while preserving project/activity/kind data.

-- Ensure project_id is available on activities before dropping phase references.
ALTER TABLE activities ADD COLUMN IF NOT EXISTS project_id INTEGER;
UPDATE activities AS a
SET project_id = p.project_id
FROM phases AS p
WHERE a.project_id IS NULL
  AND a.phase_id = p.phase_id;

ALTER TABLE activities ADD COLUMN IF NOT EXISTS title VARCHAR;
UPDATE activities
SET title = COALESCE(title, name, '')
WHERE title IS NULL;

ALTER TABLE activities ADD COLUMN IF NOT EXISTS source VARCHAR;
ALTER TABLE activities ADD COLUMN IF NOT EXISTS external_activity_id BIGINT;

-- Replace phase-specific import identity with generic variant key.
ALTER TABLE projects ADD COLUMN IF NOT EXISTS source VARCHAR;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS external_customer_id BIGINT;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS external_project_id BIGINT;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS external_variant_key VARCHAR;

DROP INDEX IF EXISTS projects_source_external_idx;

CREATE UNIQUE INDEX IF NOT EXISTS projects_source_variant_idx
    ON projects (source, external_variant_key);

-- Backup mapping rules and remove legacy FK constraints that can block activities rebuild.
CREATE SEQUENCE IF NOT EXISTS mapping_rules_seq;
CREATE TABLE IF NOT EXISTS mapping_rules (
    id INTEGER PRIMARY KEY DEFAULT nextval('mapping_rules_seq'),
    priority INTEGER NOT NULL DEFAULT 0,
    app_pattern VARCHAR,
    title_pattern VARCHAR
);
ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS project_id INTEGER;
ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS activity_id INTEGER;
ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS follow_previous BOOLEAN;
ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS created_at TIMESTAMP;
ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS rule_key VARCHAR;
ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS source VARCHAR;
ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS action_type VARCHAR;
ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS action_project_title VARCHAR;
ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS action_activity_title VARCHAR;
ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS pattern_format VARCHAR;

DROP TABLE IF EXISTS mapping_rules_backup;
CREATE TABLE mapping_rules_backup AS
SELECT
    id,
    priority,
    app_pattern,
    title_pattern,
    project_id,
    activity_id,
    follow_previous,
    created_at,
    rule_key,
    source,
    action_type,
    action_project_title,
    action_activity_title,
    pattern_format
FROM mapping_rules;
DROP TABLE IF EXISTS mapping_rules CASCADE;

-- Rebuild activities table without phase_id / phase FK.
CREATE SEQUENCE IF NOT EXISTS kinds_seq;
CREATE TABLE IF NOT EXISTS kinds (
    kind_id INTEGER PRIMARY KEY DEFAULT nextval('kinds_seq'),
    activity_id INTEGER,
    name VARCHAR,
    billable BOOLEAN
);
ALTER TABLE kinds ADD COLUMN IF NOT EXISTS billable BOOLEAN;
UPDATE kinds
SET billable = true
WHERE billable IS NULL;

DROP TABLE IF EXISTS kinds_backup;
CREATE TABLE kinds_backup AS
SELECT kind_id, activity_id, name, billable
FROM kinds;

-- Reset stale kinds_new dependency metadata seen in older databases.
DROP TABLE IF EXISTS kinds_new CASCADE;
CREATE TABLE kinds_new (
    kind_id INTEGER,
    activity_id INTEGER REFERENCES activities(activity_id),
    name VARCHAR,
    billable BOOLEAN
);
DROP TABLE kinds_new CASCADE;

DROP TABLE IF EXISTS kinds CASCADE;
DROP TABLE IF EXISTS activities_new;
CREATE TABLE activities_new (
    activity_id INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES projects(project_id),
    name VARCHAR NOT NULL,
    title VARCHAR NOT NULL,
    source VARCHAR,
    external_activity_id BIGINT
);

INSERT INTO activities_new (activity_id, project_id, name, title, source, external_activity_id)
SELECT
    a.activity_id,
    COALESCE(a.project_id, 0),
    COALESCE(a.name, a.title, ''),
    COALESCE(a.title, a.name, ''),
    a.source,
    a.external_activity_id
FROM activities AS a;

DROP TABLE activities CASCADE;
ALTER TABLE activities_new RENAME TO activities;

CREATE SEQUENCE IF NOT EXISTS kinds_seq;
CREATE TABLE IF NOT EXISTS kinds (
    kind_id INTEGER PRIMARY KEY DEFAULT nextval('kinds_seq'),
    activity_id INTEGER NOT NULL REFERENCES activities(activity_id),
    name VARCHAR NOT NULL,
    billable BOOLEAN NOT NULL DEFAULT true
);

INSERT INTO kinds (kind_id, activity_id, name, billable)
SELECT kb.kind_id, kb.activity_id, kb.name, COALESCE(kb.billable, true)
FROM kinds_backup AS kb
JOIN activities AS a ON a.activity_id = kb.activity_id;

DROP TABLE kinds_backup;
DROP TABLE IF EXISTS phases;

-- Recreate mapping_rules without legacy activity FK constraints.
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
    created_at TIMESTAMP DEFAULT current_timestamp,
    rule_key VARCHAR,
    source VARCHAR,
    action_type VARCHAR,
    action_project_title VARCHAR,
    action_activity_title VARCHAR,
    pattern_format VARCHAR
);

INSERT INTO mapping_rules (
    id,
    priority,
    app_pattern,
    title_pattern,
    project_id,
    activity_id,
    kind_id,
    is_global,
    kind_name,
    follow_previous,
    created_at,
    rule_key,
    source,
    action_type,
    action_project_title,
    action_activity_title,
    pattern_format
)
SELECT
    id,
    COALESCE(priority, 0),
    app_pattern,
    title_pattern,
    project_id,
    activity_id,
    NULL,
    false,
    NULL,
    COALESCE(follow_previous, false),
    created_at,
    rule_key,
    source,
    action_type,
    action_project_title,
    action_activity_title,
    pattern_format
FROM mapping_rules_backup;

DROP TABLE mapping_rules_backup;
CREATE UNIQUE INDEX IF NOT EXISTS uq_mapping_rules_rule_key ON mapping_rules(rule_key);

-- Advance sequence after explicit id inserts.
SELECT nextval('mapping_rules_seq')
FROM range((SELECT COALESCE(MAX(id), 0) FROM mapping_rules));
