package duckdb

import (
	"bufio"
	"database/sql"
	"fmt"
	"strings"

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
		tx, err := db.Begin()
		if err != nil {
			return fmt.Errorf("begin migration %d (%s): %w", m.Version, m.Name, err)
		}

		stmts := splitSQLStatements(m.SQL)
		for _, stmt := range stmts {
			if _, err := tx.Exec(stmt); err != nil {
				_ = tx.Rollback()
				return fmt.Errorf("apply migration %d (%s), stmt %q: %w", m.Version, m.Name, compactStmt(stmt), err)
			}
		}
		if _, err := tx.Exec(`INSERT INTO schema_migrations (version, name) VALUES (?, ?)`, m.Version, m.Name); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("record migration %d: %w", m.Version, err)
		}
		if err := tx.Commit(); err != nil {
			return fmt.Errorf("commit migration %d (%s): %w", m.Version, m.Name, err)
		}
	}

	return nil
}

func splitSQLStatements(sqlText string) []string {
	scanner := bufio.NewScanner(strings.NewReader(sqlText))
	var (
		stmts   []string
		builder strings.Builder
	)

	flush := func() {
		stmt := strings.TrimSpace(builder.String())
		builder.Reset()
		if stmt != "" {
			stmts = append(stmts, stmt)
		}
	}

	for scanner.Scan() {
		line := scanner.Text()
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "--") {
			continue
		}
		builder.WriteString(line)
		builder.WriteByte('\n')
		if strings.HasSuffix(trimmed, ";") {
			flush()
		}
	}
	flush()
	return stmts
}

func compactStmt(stmt string) string {
	flat := strings.Join(strings.Fields(stmt), " ")
	if len(flat) <= 140 {
		return flat
	}
	return flat[:140] + "..."
}
