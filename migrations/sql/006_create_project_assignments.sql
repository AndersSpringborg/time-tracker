CREATE SEQUENCE IF NOT EXISTS project_assignments_seq;
CREATE TABLE IF NOT EXISTS project_assignments (
    id INTEGER PRIMARY KEY DEFAULT nextval('project_assignments_seq'),
    project_id INTEGER NOT NULL REFERENCES projects(project_id),
    started_at TIMESTAMP DEFAULT current_timestamp,
    ended_at TIMESTAMP,
    UNIQUE(project_id, started_at)
);
