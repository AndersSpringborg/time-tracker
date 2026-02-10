CREATE SEQUENCE IF NOT EXISTS project_activities_seq;

CREATE TABLE IF NOT EXISTS project_activities (
    project_activity_id INTEGER PRIMARY KEY DEFAULT nextval('project_activities_seq'),
    project_id INTEGER NOT NULL REFERENCES projects(project_id),
    activity_id INTEGER NOT NULL REFERENCES activities(activity_id),
    created_at TIMESTAMP DEFAULT current_timestamp,
    UNIQUE(project_id, activity_id)
);

INSERT INTO project_activities (project_id, activity_id)
SELECT a.project_id, a.activity_id
FROM activities a
WHERE a.project_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1
    FROM project_activities pa
    WHERE pa.project_id = a.project_id
      AND pa.activity_id = a.activity_id
  );

ALTER TABLE mapping_rules ADD COLUMN IF NOT EXISTS project_activity_id INTEGER;
ALTER TABLE events ADD COLUMN IF NOT EXISTS project_activity_id INTEGER;

UPDATE mapping_rules mr
SET project_activity_id = pa.project_activity_id
FROM project_activities pa
WHERE mr.project_activity_id IS NULL
  AND mr.project_id = pa.project_id
  AND mr.activity_id = pa.activity_id;

UPDATE events e
SET project_activity_id = pa.project_activity_id
FROM project_activities pa
WHERE e.project_activity_id IS NULL
  AND e.project_id = pa.project_id
  AND e.activity_id = pa.activity_id;

CREATE INDEX IF NOT EXISTS idx_project_activities_project_id ON project_activities(project_id);
CREATE INDEX IF NOT EXISTS idx_project_activities_activity_id ON project_activities(activity_id);
CREATE INDEX IF NOT EXISTS idx_mapping_rules_project_activity_id ON mapping_rules(project_activity_id);
CREATE INDEX IF NOT EXISTS idx_events_project_activity_id ON events(project_activity_id);
