CREATE SEQUENCE IF NOT EXISTS suggestion_feedback_seq;

CREATE TABLE IF NOT EXISTS suggestion_feedback (
    id INTEGER PRIMARY KEY DEFAULT nextval('suggestion_feedback_seq'),
    created_at TIMESTAMP DEFAULT current_timestamp,
    suggestion_type VARCHAR NOT NULL,
    app_pattern VARCHAR NOT NULL,
    title_pattern VARCHAR,
    project_id INTEGER,
    activity_id INTEGER,
    score DOUBLE DEFAULT 0,
    confidence INTEGER DEFAULT 0,
    action VARCHAR NOT NULL,
    applied_now BOOLEAN DEFAULT false,
    date_scope VARCHAR
);
