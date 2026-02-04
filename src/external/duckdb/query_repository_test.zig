const std = @import("std");
const DuckDbQueryRepository = @import("duckdb_query_repository").DuckDbQueryRepository;
const query_repo = @import("query_repository");
const TimeRange = query_repo.TimeRange;
const migrations = @import("migrations");
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

    // Run migrations
    var migrator = try migrations.Migrator.init(conn);
    try migrator.run();

    return conn;
}

fn getTimestampMs() i64 {
    const ts = std.posix.clock_gettime(.REALTIME) catch return 0;
    const sec_ms: i64 = ts.sec * 1000;
    const nsec_ms: i64 = @divFloor(ts.nsec, 1_000_000);
    return sec_ms + nsec_ms;
}

fn insertTestEvent(conn: c.duckdb_connection, app_name: []const u8, title: []const u8, duration_ms: i64) !void {
    var stmt: c.duckdb_prepared_statement = undefined;
    const sql = "INSERT INTO events (timestamp_ms, app_name, window_title, wifi_ssid, duration_ms) VALUES (?, ?, ?, '', ?)";

    if (c.duckdb_prepare(conn, sql, &stmt) == c.DuckDBError) {
        return error.InsertFailed;
    }
    defer c.duckdb_destroy_prepare(&stmt);

    // Use current time
    const now = getTimestampMs();
    _ = c.duckdb_bind_int64(stmt, 1, now);
    _ = c.duckdb_bind_varchar_length(stmt, 2, app_name.ptr, app_name.len);
    _ = c.duckdb_bind_varchar_length(stmt, 3, title.ptr, title.len);
    _ = c.duckdb_bind_int64(stmt, 4, duration_ms);

    var result: c.duckdb_result = undefined;
    if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
        c.duckdb_destroy_result(&result);
        return error.InsertFailed;
    }
    c.duckdb_destroy_result(&result);
}

test "DuckDbQueryRepository gets app summary" {
    const conn = try openInMemoryDb();
    var repo = DuckDbQueryRepository.init(conn, std.testing.allocator);

    // Insert test events
    try insertTestEvent(conn, "Safari", "Google", 60000); // 1 min
    try insertTestEvent(conn, "Safari", "GitHub", 120000); // 2 min
    try insertTestEvent(conn, "Code", "main.zig", 240000); // 4 min (more than Safari's 3 min)

    const summaries = try repo.getAppSummary(.all);
    defer repo.freeAppSummaries(summaries);

    try std.testing.expectEqual(@as(usize, 2), summaries.len);

    // Code should be first (4 min > 3 min Safari)
    try std.testing.expect(std.mem.eql(u8, summaries[0].app_name, "Code"));
    try std.testing.expectEqual(@as(i64, 240000), summaries[0].total_ms);

    // Safari second with combined time
    try std.testing.expect(std.mem.eql(u8, summaries[1].app_name, "Safari"));
    try std.testing.expectEqual(@as(i64, 180000), summaries[1].total_ms);
}

test "DuckDbQueryRepository gets title details" {
    const conn = try openInMemoryDb();
    var repo = DuckDbQueryRepository.init(conn, std.testing.allocator);

    // Insert test events
    try insertTestEvent(conn, "Safari", "Google", 60000);
    try insertTestEvent(conn, "Safari", "GitHub", 120000);
    try insertTestEvent(conn, "Safari", "Google", 30000); // Another Google

    const details = try repo.getTitleDetails("Safari", .all);
    defer repo.freeTitleDetails(details);

    try std.testing.expectEqual(@as(usize, 2), details.len);

    // GitHub should be first (120s > 90s)
    try std.testing.expect(std.mem.eql(u8, details[0].window_title, "GitHub"));
    try std.testing.expectEqual(@as(i64, 120000), details[0].total_ms);

    // Google second with combined time
    try std.testing.expect(std.mem.eql(u8, details[1].window_title, "Google"));
    try std.testing.expectEqual(@as(i64, 90000), details[1].total_ms);
}

test "DuckDbQueryRepository gets total tracked time" {
    const conn = try openInMemoryDb();
    var repo = DuckDbQueryRepository.init(conn, std.testing.allocator);

    // Insert test events
    try insertTestEvent(conn, "Safari", "Google", 60000);
    try insertTestEvent(conn, "Code", "main.zig", 120000);

    const total = try repo.getTotalTrackedTime(.all);

    try std.testing.expectEqual(@as(i64, 180000), total);
}

test "DuckDbQueryRepository gets project name" {
    const conn = try openInMemoryDb();
    var repo = DuckDbQueryRepository.init(conn, std.testing.allocator);

    // Insert test customer and project
    var result: c.duckdb_result = undefined;
    _ = c.duckdb_query(conn, "INSERT INTO customers (customer_id, name) VALUES (1, 'Acme Corp')", &result);
    c.duckdb_destroy_result(&result);

    _ = c.duckdb_query(conn, "INSERT INTO projects (project_id, customer_id, name) VALUES (10, 1, 'Website')", &result);
    c.duckdb_destroy_result(&result);

    const name = try repo.getProjectName(10);
    try std.testing.expect(name != null);
    defer repo.freeName(name.?);

    try std.testing.expect(std.mem.eql(u8, name.?, "Acme Corp > Website"));
}

test "DuckDbQueryRepository returns null for unknown project" {
    const conn = try openInMemoryDb();
    var repo = DuckDbQueryRepository.init(conn, std.testing.allocator);

    const name = try repo.getProjectName(99999);
    try std.testing.expect(name == null);
}
