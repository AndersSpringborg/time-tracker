const std = @import("std");
const Event = @import("domain_event").Event;
const DuckDbEventRepository = @import("duckdb_event_repository").DuckDbEventRepository;
const migrations = @import("migrations");
const c = migrations.c;
const Migrator = migrations.Migrator;

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
    var migrator = try Migrator.init(conn);
    try migrator.run();

    return conn;
}

test "DuckDbEventRepository saves and retrieves events" {
    const conn = try openInMemoryDb();
    var repo = DuckDbEventRepository.init(conn, std.testing.allocator);

    const event = Event{
        .timestamp_ms = 1000,
        .app_name = "Safari",
        .window_title = "Google",
        .wifi_ssid = "Home",
    };

    repo.save(event, 500, null);

    try std.testing.expectEqual(@as(i64, 1), repo.countEvents());

    const last = repo.getLastEvent();
    try std.testing.expect(last != null);
    try std.testing.expectEqualStrings("Safari", last.?.app_name);
    try std.testing.expectEqual(@as(i64, 500), last.?.duration_ms);
}

test "DuckDbEventRepository saves event with rule match" {
    const conn = try openInMemoryDb();
    var repo = DuckDbEventRepository.init(conn, std.testing.allocator);

    const event = Event{
        .timestamp_ms = 1000,
        .app_name = "Code",
        .window_title = "main.zig",
        .wifi_ssid = "Office",
    };

    const event_repository = @import("event_repository");
    repo.save(event, 1000, event_repository.RuleMatch{
        .rule_id = 1,
        .activity_id = 10,
        .kind_id = 20,
    });

    const last = repo.getLastEvent();
    try std.testing.expect(last != null);
    try std.testing.expectEqual(@as(?i64, 10), last.?.activity_id);
    try std.testing.expectEqual(@as(?i64, 20), last.?.kind_id);
}

test "DuckDbEventRepository works through interface" {
    const conn = try openInMemoryDb();
    var duck_repo = DuckDbEventRepository.init(conn, std.testing.allocator);

    const repo = duck_repo.repository();

    const event = Event{
        .timestamp_ms = 2000,
        .app_name = "Terminal",
        .window_title = "zsh",
        .wifi_ssid = "Home",
    };

    repo.save(event, 300, null);
    try std.testing.expectEqual(@as(i64, 1), repo.countEvents());
}
