const std = @import("std");
const migrations = @import("migrations.zig");
const Migrator = migrations.Migrator;
const MigrationError = migrations.MigrationError;
const c = migrations.c;

fn openInMemoryDb() !c.duckdb_connection {
    var db: c.duckdb_database = undefined;
    var conn: c.duckdb_connection = undefined;

    if (c.duckdb_open(":memory:", &db) == c.DuckDBError) {
        return error.OpenFailed;
    }

    if (c.duckdb_connect(db, &conn) == c.DuckDBError) {
        c.duckdb_close(&db);
        return error.ConnectFailed;
    }

    return conn;
}

fn tableExists(conn: c.duckdb_connection, table_name: []const u8) bool {
    var buf: [256]u8 = undefined;
    const query = std.fmt.bufPrintZ(&buf, "SELECT 1 FROM {s} LIMIT 1", .{table_name}) catch return false;

    var result: c.duckdb_result = undefined;
    const success = c.duckdb_query(conn, query.ptr, &result) != c.DuckDBError;
    c.duckdb_destroy_result(&result);
    return success;
}

fn columnExists(conn: c.duckdb_connection, table_name: []const u8, column_name: []const u8) bool {
    var buf: [256]u8 = undefined;
    const query = std.fmt.bufPrintZ(&buf, "SELECT {s} FROM {s} LIMIT 1", .{ column_name, table_name }) catch return false;

    var result: c.duckdb_result = undefined;
    const success = c.duckdb_query(conn, query.ptr, &result) != c.DuckDBError;
    c.duckdb_destroy_result(&result);
    return success;
}

// Test 1: Migrator.init creates schema_migrations table
test "Migrator.init creates schema_migrations table" {
    const conn = try openInMemoryDb();
    _ = try Migrator.init(conn);

    try std.testing.expect(tableExists(conn, "schema_migrations"));
}

// Test 2: getCurrentVersion returns 0 for fresh database
test "Migrator.getCurrentVersion returns 0 for fresh db" {
    const conn = try openInMemoryDb();
    var migrator = try Migrator.init(conn);

    const version = try migrator.getCurrentVersion();
    try std.testing.expectEqual(@as(u32, 0), version);
}

// Test 3: run applies pending migrations
test "Migrator.run applies pending migrations" {
    const conn = try openInMemoryDb();
    var migrator = try Migrator.init(conn);

    try migrator.run();

    // After running migrations, events table should exist
    try std.testing.expect(tableExists(conn, "events"));
}

// Test 4: run is idempotent - safe to call multiple times
test "Migrator.run is idempotent" {
    const conn = try openInMemoryDb();
    var migrator = try Migrator.init(conn);

    // Run migrations multiple times
    try migrator.run();
    try migrator.run();
    try migrator.run();

    // Should still work, no errors
    try std.testing.expect(tableExists(conn, "events"));
}

// Test 5: migrations are applied in order
test "Migrator.run applies migrations in order" {
    const conn = try openInMemoryDb();
    var migrator = try Migrator.init(conn);

    try migrator.run();

    // Migration 1 creates events table
    try std.testing.expect(tableExists(conn, "events"));

    // Migration 2 adds wifi_ssid column
    try std.testing.expect(columnExists(conn, "events", "wifi_ssid"));
}

// Test 6: getCurrentVersion returns highest applied version
test "Migrator.getCurrentVersion returns highest applied version after run" {
    const conn = try openInMemoryDb();
    var migrator = try Migrator.init(conn);

    try migrator.run();

    const version = try migrator.getCurrentVersion();
    // Should be 10 after running all migrations
    try std.testing.expectEqual(@as(u32, 10), version);
}

// Test 7: simplified project/activity tables are created
test "Migrator.run creates simplified project tables" {
    const conn = try openInMemoryDb();
    var migrator = try Migrator.init(conn);

    try migrator.run();

    try std.testing.expect(tableExists(conn, "projects"));
    try std.testing.expect(tableExists(conn, "activities"));
    try std.testing.expect(tableExists(conn, "customers"));
    try std.testing.expect(tableExists(conn, "phases"));
    try std.testing.expect(!tableExists(conn, "kinds_new"));
    try std.testing.expect(!tableExists(conn, "kinds"));
    try std.testing.expect(columnExists(conn, "projects", "title"));
    try std.testing.expect(columnExists(conn, "activities", "title"));
}

// Test 8: mapping_rules table is created
test "Migrator.run creates mapping_rules table" {
    const conn = try openInMemoryDb();
    var migrator = try Migrator.init(conn);

    try migrator.run();

    // Migration 4 creates mapping_rules table
    try std.testing.expect(tableExists(conn, "mapping_rules"));
}

// Test 9: event mapping columns are added
test "Migrator.run adds event mapping columns" {
    const conn = try openInMemoryDb();
    var migrator = try Migrator.init(conn);

    try migrator.run();

    // Migration 5 adds mapping columns to events
    try std.testing.expect(columnExists(conn, "events", "activity_id"));
    try std.testing.expect(columnExists(conn, "events", "kind_id"));
    try std.testing.expect(columnExists(conn, "events", "manually_mapped"));
}

// Test 10: project_assignments table is created
test "Migrator.run creates project_assignments table" {
    const conn = try openInMemoryDb();
    var migrator = try Migrator.init(conn);

    try migrator.run();

    // Migration 6 creates project_assignments table
    try std.testing.expect(tableExists(conn, "project_assignments"));
    try std.testing.expect(columnExists(conn, "project_assignments", "project_id"));
    try std.testing.expect(columnExists(conn, "project_assignments", "started_at"));
    try std.testing.expect(columnExists(conn, "project_assignments", "ended_at"));
}

// Test 11: follow_previous column is added to mapping_rules
test "Migrator.run adds follow_previous to mapping_rules" {
    const conn = try openInMemoryDb();
    var migrator = try Migrator.init(conn);

    try migrator.run();

    try std.testing.expect(columnExists(conn, "mapping_rules", "follow_previous"));
}

// Test 12: project_id column is added to events
test "Migrator.run adds project_id to events" {
    const conn = try openInMemoryDb();
    var migrator = try Migrator.init(conn);

    try migrator.run();

    try std.testing.expect(columnExists(conn, "events", "project_id"));
}
