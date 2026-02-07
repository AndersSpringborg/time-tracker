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
        .up = @embedFile("sql/001_create_events_table.sql"),
    },
    .{
        .version = 2,
        .name = "add_wifi_ssid",
        .up = @embedFile("sql/002_add_wifi_ssid.sql"),
    },
    .{
        .version = 3,
        .name = "create_hierarchy_tables",
        .up = @embedFile("sql/003_create_hierarchy_tables.sql"),
    },
    .{
        .version = 4,
        .name = "create_mapping_rules",
        .up = @embedFile("sql/004_create_mapping_rules.sql"),
    },
    .{
        .version = 5,
        .name = "add_event_mapping_columns",
        .up = @embedFile("sql/005_add_event_mapping_columns.sql"),
    },
    .{
        .version = 6,
        .name = "create_project_assignments",
        .up = @embedFile("sql/006_create_project_assignments.sql"),
    },
    .{
        .version = 7,
        .name = "add_global_rules_support",
        .up = @embedFile("sql/007_add_global_rules_support.sql"),
    },
    .{
        .version = 8,
        .name = "fix_kinds_composite_primary_key",
        .up = @embedFile("sql/008_fix_kinds_composite_primary_key.sql"),
    },
    .{
        .version = 9,
        .name = "add_follow_previous_rules",
        .up = @embedFile("sql/009_add_follow_previous_rules.sql"),
    },
    .{
        .version = 10,
        .name = "simplify_project_activity_model",
        .up = @embedFile("sql/010_simplify_project_activity_model.sql"),
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
        self.execQuery(migration.up) catch {
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

    fn execQuery(self: *Migrator, sql: []const u8) MigrationError!void {
        const sql_z = std.heap.page_allocator.dupeZ(u8, sql) catch return MigrationError.QueryFailed;
        defer std.heap.page_allocator.free(sql_z);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_query(self.conn, sql_z.ptr, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return MigrationError.QueryFailed;
        }
        c.duckdb_destroy_result(&result);
    }
};
