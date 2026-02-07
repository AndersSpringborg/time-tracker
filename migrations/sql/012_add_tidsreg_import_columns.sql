ALTER TABLE projects ADD COLUMN IF NOT EXISTS source VARCHAR;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS external_customer_id BIGINT;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS external_project_id BIGINT;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS external_phase_id BIGINT;

ALTER TABLE activities ADD COLUMN IF NOT EXISTS source VARCHAR;
ALTER TABLE activities ADD COLUMN IF NOT EXISTS external_activity_id BIGINT;

CREATE UNIQUE INDEX IF NOT EXISTS projects_source_external_idx
    ON projects (source, external_customer_id, external_project_id, external_phase_id);

CREATE UNIQUE INDEX IF NOT EXISTS activities_source_project_external_idx
    ON activities (source, project_id, external_activity_id);
