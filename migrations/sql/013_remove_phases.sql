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

-- Rebuild activities table without phase_id / phase FK.
DROP TABLE IF EXISTS kinds_backup;
CREATE TABLE kinds_backup AS
SELECT kind_id, activity_id, name, billable
FROM kinds;

DROP TABLE IF EXISTS kinds;
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

DROP TABLE activities;
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

-- Replace phase-specific import identity with generic variant key.
ALTER TABLE projects ADD COLUMN IF NOT EXISTS source VARCHAR;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS external_customer_id BIGINT;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS external_project_id BIGINT;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS external_variant_key VARCHAR;

UPDATE projects
SET external_variant_key =
    COALESCE(source, '') || ':' ||
    COALESCE(CAST(external_customer_id AS VARCHAR), '') || ':' ||
    COALESCE(CAST(external_project_id AS VARCHAR), '') || ':' ||
    COALESCE(CAST(external_phase_id AS VARCHAR), '')
WHERE external_variant_key IS NULL
  AND source IS NOT NULL;

DROP INDEX IF EXISTS projects_source_external_idx;

CREATE UNIQUE INDEX IF NOT EXISTS projects_source_variant_idx
    ON projects (source, external_variant_key);
