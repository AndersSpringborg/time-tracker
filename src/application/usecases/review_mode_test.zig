const std = @import("std");
const testing = std.testing;
const migrations = @import("migrations");
const review = @import("review");
const ReviewModeUseCase = @import("review_mode.zig").ReviewModeUseCase;
const c = migrations.c;

fn setupTestDb() !c.duckdb_connection {
    var db: c.duckdb_database = undefined;
    var conn: c.duckdb_connection = undefined;

    if (c.duckdb_open(":memory:", &db) == c.DuckDBError) {
        return error.OpenFailed;
    }

    if (c.duckdb_connect(db, &conn) == c.DuckDBError) {
        return error.ConnectFailed;
    }

    var migrator = try migrations.Migrator.init(conn);
    try migrator.run();

    return conn;
}

fn execQuery(conn: c.duckdb_connection, sql: [*c]const u8) !void {
    var result: c.duckdb_result = undefined;
    if (c.duckdb_query(conn, sql, &result) == c.DuckDBError) {
        c.duckdb_destroy_result(&result);
        return error.QueryFailed;
    }
    c.duckdb_destroy_result(&result);
}

test "ReviewModeUseCase toggles short event filter" {
    const conn = try setupTestDb();
    const reviewer = review.Reviewer.init(conn, testing.allocator);
    var usecase = ReviewModeUseCase.init(reviewer);

    try testing.expect(usecase.isShortEventFilterEnabled());
    try testing.expectEqual(ReviewModeUseCase.shortEventThresholdMs, usecase.getMinDurationMs());

    _ = usecase.toggleShortEventFilter();
    try testing.expect(!usecase.isShortEventFilterEnabled());
    try testing.expectEqual(@as(i64, 0), usecase.getMinDurationMs());
}

test "ReviewModeUseCase applies filter in timeline fetch" {
    const conn = try setupTestDb();
    try execQuery(conn, "INSERT INTO events (timestamp_ms, app_name, window_title, wifi_ssid, duration_ms) VALUES (1000, 'Code', 'short', 'Office', 1500)");
    try execQuery(conn, "INSERT INTO events (timestamp_ms, app_name, window_title, wifi_ssid, duration_ms) VALUES (2000, 'Code', 'long', 'Office', 2500)");

    const reviewer = review.Reviewer.init(conn, testing.allocator);
    var usecase = ReviewModeUseCase.init(reviewer);

    const dates = try usecase.getDatesWithUnmappedEvents();
    defer testing.allocator.free(dates);
    try testing.expect(dates.len > 0);

    const filtered = try usecase.getTimelineEventsForDate(dates[0].slice());
    defer testing.allocator.free(filtered);
    try testing.expectEqual(@as(usize, 1), filtered.len);

    _ = usecase.toggleShortEventFilter();
    const unfiltered = try usecase.getTimelineEventsForDate(dates[0].slice());
    defer testing.allocator.free(unfiltered);
    try testing.expectEqual(@as(usize, 2), unfiltered.len);
}
