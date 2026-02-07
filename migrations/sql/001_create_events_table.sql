CREATE SEQUENCE IF NOT EXISTS events_seq;
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY DEFAULT nextval('events_seq'),
    timestamp_ms BIGINT NOT NULL,
    app_name VARCHAR NOT NULL,
    window_title VARCHAR NOT NULL,
    duration_ms BIGINT NOT NULL,
    created_at TIMESTAMP DEFAULT current_timestamp
);
