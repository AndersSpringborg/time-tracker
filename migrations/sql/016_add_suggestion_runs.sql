CREATE SEQUENCE IF NOT EXISTS suggestion_runs_seq;

CREATE TABLE IF NOT EXISTS suggestion_runs (
    id INTEGER PRIMARY KEY DEFAULT nextval('suggestion_runs_seq'),
    created_at TIMESTAMP DEFAULT current_timestamp,
    date_scope VARCHAR,
    min_duration_ms BIGINT NOT NULL DEFAULT 0,
    suggestion_limit INTEGER NOT NULL DEFAULT 0,
    min_evidence INTEGER NOT NULL DEFAULT 0,
    min_confidence INTEGER NOT NULL DEFAULT 0,
    include_context BOOLEAN NOT NULL DEFAULT false,
    apply_now BOOLEAN NOT NULL DEFAULT false,
    analyzed_count INTEGER NOT NULL DEFAULT 0,
    accepted_count INTEGER NOT NULL DEFAULT 0,
    mapped_events BIGINT NOT NULL DEFAULT 0
);
