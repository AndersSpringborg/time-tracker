package duckdb

import (
	"database/sql"
	"fmt"

	_ "github.com/duckdb/duckdb-go/v2"
)

func openDB(path string) (*sql.DB, error) {
	db, err := sql.Open("duckdb", path)
	if err != nil {
		return nil, fmt.Errorf("open duckdb: %w", err)
	}

	if _, err := db.Exec("PRAGMA journal_mode=WAL;"); err != nil {
		// best effort
	}

	if err := migrate(db); err != nil {
		_ = db.Close()
		return nil, err
	}
	if _, err := db.Exec("CHECKPOINT;"); err != nil {
		// best effort to avoid replaying large or problematic WAL state
	}

	return db, nil
}
