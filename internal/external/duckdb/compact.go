package duckdb

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// CompactResult describes what a compaction did, so the caller can report the
// space reclaimed and prove nothing was lost.
type CompactResult struct {
	BackupPath    string
	SchemaVersion int64
	Rows          map[string]int64
	BytesBefore   int64
	BytesAfter    int64
}

// Compact rewrites the database to reclaim storage DuckDB does not return to
// the operating system on its own. Deleting rows or running CHECKPOINT does not
// shrink the file; only an export into a fresh database does.
//
// The database must not be open by any process, including the collector. The
// original file is kept as a timestamped backup rather than deleted.
func Compact(ctx context.Context, path string) (CompactResult, error) {
	result := CompactResult{Rows: map[string]int64{}}
	info, err := os.Stat(path)
	if err != nil {
		return result, fmt.Errorf("stat database: %w", err)
	}
	result.BytesBefore = info.Size()

	exportDir, err := os.MkdirTemp(filepath.Dir(path), "tracker-compact-")
	if err != nil {
		return result, fmt.Errorf("create export directory: %w", err)
	}
	defer os.RemoveAll(exportDir)

	if err := exportDatabase(ctx, path, exportDir, &result); err != nil {
		return result, err
	}

	compacted := path + ".compacting"
	_ = os.Remove(compacted)
	if err := importDatabase(ctx, compacted, exportDir, result); err != nil {
		_ = os.Remove(compacted)
		return result, err
	}

	backup := fmt.Sprintf("%s.backup-%s", path, time.Now().Format("20060102-150405"))
	if err := os.Rename(path, backup); err != nil {
		_ = os.Remove(compacted)
		return result, fmt.Errorf("back up original database: %w", err)
	}
	if err := os.Rename(compacted, path); err != nil {
		// Put the original back rather than leaving no database at all.
		_ = os.Rename(backup, path)
		_ = os.Remove(compacted)
		return result, fmt.Errorf("install compacted database: %w", err)
	}
	result.BackupPath = backup

	if info, err = os.Stat(path); err == nil {
		result.BytesAfter = info.Size()
	}
	return result, nil
}

// exportDatabase reads the source database and writes it to exportDir, also
// recording the row counts used to verify the rewritten copy.
func exportDatabase(ctx context.Context, path, exportDir string, result *CompactResult) error {
	db, err := sql.Open("duckdb", path)
	if err != nil {
		return fmt.Errorf("open duckdb: %w", err)
	}
	defer db.Close()

	tables, err := userTables(ctx, db)
	if err != nil {
		return err
	}
	for _, table := range tables {
		var count int64
		if err := db.QueryRowContext(ctx, `SELECT count(*) FROM "`+table+`"`).Scan(&count); err != nil {
			return fmt.Errorf("count %s: %w", table, err)
		}
		result.Rows[table] = count
	}
	if err := db.QueryRowContext(ctx, `SELECT coalesce(max(version), 0) FROM schema_migrations`).
		Scan(&result.SchemaVersion); err != nil {
		return fmt.Errorf("read schema version: %w", err)
	}

	// Parquet keeps types exact; CSV would round-trip timestamps and NULLs as text.
	if _, err := db.ExecContext(ctx, `EXPORT DATABASE '`+exportDir+`' (FORMAT PARQUET)`); err != nil {
		return fmt.Errorf("export database: %w", err)
	}
	return db.Close()
}

// importDatabase builds the replacement database and refuses to install one
// whose contents do not match the original.
func importDatabase(ctx context.Context, compacted, exportDir string, expected CompactResult) error {
	db, err := sql.Open("duckdb", compacted)
	if err != nil {
		return fmt.Errorf("create compacted database: %w", err)
	}
	defer db.Close()

	// IMPORT DATABASE inserts parents before children; COPY FROM DATABASE does
	// not and fails on this schema's foreign keys.
	if _, err := db.ExecContext(ctx, `IMPORT DATABASE '`+exportDir+`'`); err != nil {
		return fmt.Errorf("import database: %w", err)
	}
	for table, want := range expected.Rows {
		var got int64
		if err := db.QueryRowContext(ctx, `SELECT count(*) FROM "`+table+`"`).Scan(&got); err != nil {
			return fmt.Errorf("verify %s: %w", table, err)
		}
		if got != want {
			return fmt.Errorf("verify %s: %d rows after compaction, %d before", table, got, want)
		}
	}
	var version int64
	if err := db.QueryRowContext(ctx, `SELECT coalesce(max(version), 0) FROM schema_migrations`).Scan(&version); err != nil {
		return fmt.Errorf("verify schema version: %w", err)
	}
	if version != expected.SchemaVersion {
		return fmt.Errorf("verify schema version: %d after compaction, %d before", version, expected.SchemaVersion)
	}
	if _, err := db.ExecContext(ctx, "CHECKPOINT;"); err != nil {
		return fmt.Errorf("checkpoint compacted database: %w", err)
	}
	return db.Close()
}

func userTables(ctx context.Context, db *sql.DB) ([]string, error) {
	rows, err := db.QueryContext(ctx,
		`SELECT table_name FROM information_schema.tables WHERE table_schema = 'main' AND table_type = 'BASE TABLE'`)
	if err != nil {
		return nil, fmt.Errorf("list tables: %w", err)
	}
	defer rows.Close()
	var tables []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		tables = append(tables, name)
	}
	sort.Strings(tables)
	return tables, rows.Err()
}
