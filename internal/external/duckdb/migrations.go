package duckdb

import (
	"database/sql"
	"fmt"

	sharedmigrations "time-tracker/migrations"
)

func migrate(db *sql.DB) error {
	migrations, err := sharedmigrations.Load()
	if err != nil {
		return fmt.Errorf("load migrations: %w", err)
	}

	if _, err := db.Exec(`
CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    name VARCHAR NOT NULL,
    applied_at TIMESTAMP DEFAULT current_timestamp
);
`); err != nil {
		return fmt.Errorf("create schema_migrations: %w", err)
	}

	currentVersion := 0
	if err := db.QueryRow(`SELECT COALESCE(MAX(version), 0) FROM schema_migrations`).Scan(&currentVersion); err != nil {
		return fmt.Errorf("read schema_migrations: %w", err)
	}

	for _, m := range migrations {
		if m.Version <= currentVersion {
			continue
		}
		if _, err := db.Exec(m.SQL); err != nil {
			return fmt.Errorf("apply migration %d (%s): %w", m.Version, m.Name, err)
		}
		if _, err := db.Exec(`INSERT INTO schema_migrations (version, name) VALUES (?, ?)`, m.Version, m.Name); err != nil {
			return fmt.Errorf("record migration %d: %w", m.Version, err)
		}
	}

	return nil
}
