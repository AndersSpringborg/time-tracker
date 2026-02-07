CREATE SEQUENCE IF NOT EXISTS mapping_rules_seq;
CREATE TABLE IF NOT EXISTS mapping_rules (
    id INTEGER PRIMARY KEY DEFAULT nextval('mapping_rules_seq'),
    priority INTEGER NOT NULL DEFAULT 0,
    app_pattern VARCHAR,
    title_pattern VARCHAR,
    activity_id INTEGER,
    kind_id INTEGER,
    created_at TIMESTAMP DEFAULT current_timestamp
);
