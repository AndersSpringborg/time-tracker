ALTER TABLE projects ADD COLUMN IF NOT EXISTS archived_at TIMESTAMP;

CREATE INDEX IF NOT EXISTS idx_projects_archived_at ON projects(archived_at);

CREATE TABLE IF NOT EXISTS archived_projects (
    project_id INTEGER PRIMARY KEY REFERENCES projects(project_id),
    archived_at TIMESTAMP DEFAULT current_timestamp
);
