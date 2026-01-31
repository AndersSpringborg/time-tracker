const std = @import("std");
const hierarchy = @import("hierarchy");
const HierarchyImporter = hierarchy.HierarchyImporter;
const migrations = @import("migrations");
const Migrator = migrations.Migrator;
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

fn setupDb(conn: c.duckdb_connection) !void {
    var migrator = try Migrator.init(conn);
    try migrator.run();
}

fn getRowCount(conn: c.duckdb_connection, table: []const u8) !i64 {
    var buf: [256]u8 = undefined;
    const query = std.fmt.bufPrintZ(&buf, "SELECT COUNT(*) FROM {s}", .{table}) catch return error.BufferError;

    var result: c.duckdb_result = undefined;
    if (c.duckdb_query(conn, query.ptr, &result) == c.DuckDBError) {
        return error.QueryFailed;
    }
    defer c.duckdb_destroy_result(&result);

    return c.duckdb_value_int64(&result, 0, 0);
}

// Test 1: Import minimal JSON structure
test "HierarchyImporter imports minimal customer" {
    const conn = try openInMemoryDb();
    try setupDb(conn);

    var importer = HierarchyImporter.init(conn, std.testing.allocator);

    const json =
        \\[{
        \\  "CustomerId": 1,
        \\  "Name": "Test Customer",
        \\  "Projects": []
        \\}]
    ;

    const stats = try importer.importFromJson(json);

    try std.testing.expectEqual(@as(u32, 1), stats.customers);
    try std.testing.expectEqual(@as(u32, 0), stats.projects);

    const count = try getRowCount(conn, "customers");
    try std.testing.expectEqual(@as(i64, 1), count);
}

// Test 2: Import full hierarchy
test "HierarchyImporter imports full hierarchy" {
    const conn = try openInMemoryDb();
    try setupDb(conn);

    var importer = HierarchyImporter.init(conn, std.testing.allocator);

    const json =
        \\[{
        \\  "CustomerId": 100,
        \\  "Name": "ACME Corp",
        \\  "Projects": [{
        \\    "id": "Project Alpha",
        \\    "ProjectId": 200,
        \\    "Phases": [{
        \\      "PhaseId": 300,
        \\      "Name": "Development",
        \\      "Activities": [{
        \\        "ActivityId": 400,
        \\        "BackendId": null,
        \\        "Name": "Billable",
        \\        "Kinds": [{
        \\          "KindId": 500,
        \\          "BackendId": "TEST",
        \\          "Name": "Standard"
        \\        }]
        \\      }]
        \\    }]
        \\  }]
        \\}]
    ;

    const stats = try importer.importFromJson(json);

    try std.testing.expectEqual(@as(u32, 1), stats.customers);
    try std.testing.expectEqual(@as(u32, 1), stats.projects);
    try std.testing.expectEqual(@as(u32, 1), stats.phases);
    try std.testing.expectEqual(@as(u32, 1), stats.activities);
    try std.testing.expectEqual(@as(u32, 1), stats.kinds);
}

// Test 3: Import is idempotent (can be run multiple times)
test "HierarchyImporter import is idempotent" {
    const conn = try openInMemoryDb();
    try setupDb(conn);

    var importer = HierarchyImporter.init(conn, std.testing.allocator);

    const json =
        \\[{
        \\  "CustomerId": 1,
        \\  "Name": "Test Customer",
        \\  "Projects": []
        \\}]
    ;

    // Import twice
    _ = try importer.importFromJson(json);
    _ = try importer.importFromJson(json);

    const count = try getRowCount(conn, "customers");
    try std.testing.expectEqual(@as(i64, 1), count);
}

// Test 4: Billable detection from activity name
test "HierarchyImporter detects non-billable activities" {
    const conn = try openInMemoryDb();
    try setupDb(conn);

    var importer = HierarchyImporter.init(conn, std.testing.allocator);

    const json =
        \\[{
        \\  "CustomerId": 100,
        \\  "Name": "Test",
        \\  "Projects": [{
        \\    "id": "Project",
        \\    "ProjectId": 200,
        \\    "Phases": [{
        \\      "PhaseId": 300,
        \\      "Name": "Phase",
        \\      "Activities": [
        \\        {
        \\          "ActivityId": 401,
        \\          "BackendId": null,
        \\          "Name": "Billable",
        \\          "Kinds": [{"KindId": 501, "BackendId": null, "Name": "K1"}]
        \\        },
        \\        {
        \\          "ActivityId": 402,
        \\          "BackendId": null,
        \\          "Name": "Not billable",
        \\          "Kinds": [{"KindId": 502, "BackendId": null, "Name": "K2"}]
        \\        }
        \\      ]
        \\    }]
        \\  }]
        \\}]
    ;

    _ = try importer.importFromJson(json);

    // Query to check billable flag
    var result: c.duckdb_result = undefined;
    const query = "SELECT billable FROM kinds ORDER BY kind_id";
    if (c.duckdb_query(conn, query, &result) == c.DuckDBError) {
        return error.QueryFailed;
    }
    defer c.duckdb_destroy_result(&result);

    const billable1 = c.duckdb_value_boolean(&result, 0, 0);
    const billable2 = c.duckdb_value_boolean(&result, 0, 1);

    try std.testing.expect(billable1); // "Billable" activity should be billable
    try std.testing.expect(!billable2); // "Not billable" activity should not be billable
}
