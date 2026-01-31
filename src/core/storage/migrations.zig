const std = @import("std");
pub const c = @cImport({
    @cInclude("duckdb.h");
});

pub const MigrationError = error{
    QueryFailed,
    InitFailed,
};

pub const Migration = struct {
    version: u32,
    name: []const u8,
    up: []const u8,
};

/// All migrations in order. Add new migrations to the end.
pub const migrations = [_]Migration{
    .{
        .version = 1,
        .name = "create_events_table",
        .up =
        \\CREATE SEQUENCE IF NOT EXISTS events_seq;
        \\CREATE TABLE events (
        \\    id INTEGER PRIMARY KEY DEFAULT nextval('events_seq'),
        \\    timestamp_ms BIGINT NOT NULL,
        \\    app_name VARCHAR NOT NULL,
        \\    window_title VARCHAR NOT NULL,
        \\    duration_ms BIGINT NOT NULL,
        \\    created_at TIMESTAMP DEFAULT current_timestamp
        \\)
        ,
    },
    .{
        .version = 2,
        .name = "add_wifi_ssid",
        .up = "ALTER TABLE events ADD COLUMN wifi_ssid VARCHAR DEFAULT ''",
    },
};

pub const Migrator = struct {
    conn: c.duckdb_connection,

    const schema_migrations_sql =
        \\CREATE TABLE IF NOT EXISTS schema_migrations (
        \\    version INTEGER PRIMARY KEY,
        \\    name VARCHAR NOT NULL,
        \\    applied_at TIMESTAMP DEFAULT current_timestamp
        \\)
    ;

    pub fn init(conn: c.duckdb_connection) MigrationError!Migrator {
        var migrator = Migrator{ .conn = conn };

        // Create schema_migrations table
        migrator.execQuery(schema_migrations_sql) catch {
            return MigrationError.InitFailed;
        };

        return migrator;
    }

    pub fn run(self: *Migrator) MigrationError!void {
        const current_version = try self.getCurrentVersion();

        for (migrations) |migration| {
            if (migration.version > current_version) {
                try self.applyMigration(migration);
            }
        }
    }

    pub fn getCurrentVersion(self: *Migrator) MigrationError!u32 {
        var result: c.duckdb_result = undefined;
        const query = "SELECT COALESCE(MAX(version), 0) FROM schema_migrations";

        if (c.duckdb_query(self.conn, query, &result) == c.DuckDBError) {
            return MigrationError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const version = c.duckdb_value_int64(&result, 0, 0);
        return @intCast(version);
    }

    fn applyMigration(self: *Migrator, migration: Migration) MigrationError!void {
        // Run the migration SQL
        self.execQuery(migration.up.ptr) catch {
            std.debug.print("Migration {d} ({s}) failed\n", .{ migration.version, migration.name });
            return MigrationError.QueryFailed;
        };

        // Record the migration
        try self.recordMigration(migration);
    }

    fn recordMigration(self: *Migrator, migration: Migration) MigrationError!void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const insert_sql = "INSERT INTO schema_migrations (version, name) VALUES (?, ?)";

        if (c.duckdb_prepare(self.conn, insert_sql, &stmt) == c.DuckDBError) {
            return MigrationError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int32(stmt, 1, @intCast(migration.version));
        _ = c.duckdb_bind_varchar_length(stmt, 2, migration.name.ptr, migration.name.len);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return MigrationError.QueryFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    fn execQuery(self: *Migrator, sql: [*c]const u8) MigrationError!void {
        var result: c.duckdb_result = undefined;
        if (c.duckdb_query(self.conn, sql, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return MigrationError.QueryFailed;
        }
        c.duckdb_destroy_result(&result);
    }
};
