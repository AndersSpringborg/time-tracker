CREATE TABLE IF NOT EXISTS ingestion_producers (
    producer_id VARCHAR PRIMARY KEY,
    acknowledged_sequence BIGINT NOT NULL CHECK (acknowledged_sequence > 0)
);
