-- Historical detail is summarised per day before it is deleted, so totals and
-- trends survive retention even when window-level detail does not.
-- project_id/activity_id use 0 for "unmapped" because primary key columns
-- cannot be NULL; the wifi dimension is kept so work/non-work classification
-- can still be recomputed from current settings rather than frozen at
-- summarisation time.
CREATE TABLE IF NOT EXISTS daily_summaries (
    day DATE NOT NULL,
    project_id INTEGER NOT NULL DEFAULT 0,
    activity_id INTEGER NOT NULL DEFAULT 0,
    app_name VARCHAR NOT NULL,
    wifi_ssid VARCHAR NOT NULL DEFAULT '',
    total_ms BIGINT NOT NULL,
    event_count BIGINT NOT NULL,
    PRIMARY KEY (day, project_id, activity_id, app_name, wifi_ssid)
);

-- One row per summarised day. detail_deleted decides which source a report
-- reads that day from, so a day is never counted from both.
CREATE TABLE IF NOT EXISTS summary_coverage (
    day DATE PRIMARY KEY,
    summarized_at TIMESTAMP NOT NULL DEFAULT current_timestamp,
    detail_deleted BOOLEAN NOT NULL DEFAULT false,
    event_count BIGINT NOT NULL,
    total_ms BIGINT NOT NULL
);

-- Every date-range query filters on timestamp_ms and there was no index on it.
CREATE INDEX IF NOT EXISTS idx_events_timestamp_ms ON events(timestamp_ms);
