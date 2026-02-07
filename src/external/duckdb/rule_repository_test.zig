const std = @import("std");
const domain_rule = @import("domain_rule");
const RuleInput = domain_rule.RuleInput;
const DuckDbRuleRepository = @import("duckdb_rule_repository").DuckDbRuleRepository;
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

test "DuckDbRuleRepository adds and counts rules" {
    const conn = try openInMemoryDb();
    var repo = DuckDbRuleRepository.init(conn, std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 0), try repo.getRuleCount());

    try repo.addRule(.{
        .app_pattern = "Safari",
        .title_pattern = null,
        .activity_id = 1,
        .kind_id = 1,
        .priority = 10,
    });

    try std.testing.expectEqual(@as(i64, 1), try repo.getRuleCount());

    try repo.addRule(.{
        .app_pattern = "Code",
        .title_pattern = "*.zig",
        .activity_id = 2,
        .kind_id = 3,
        .priority = 20,
    });

    try std.testing.expectEqual(@as(i64, 2), try repo.getRuleCount());
}

test "DuckDbRuleRepository finds matching rule" {
    const conn = try openInMemoryDb();
    var repo = DuckDbRuleRepository.init(conn, std.testing.allocator);

    try repo.addRule(.{
        .app_pattern = "Safari",
        .title_pattern = null,
        .activity_id = 1,
        .kind_id = 10,
        .priority = 0,
    });

    const match = try repo.findMatch("Safari", "Google Search");
    try std.testing.expect(match != null);
    try std.testing.expectEqual(domain_rule.MatchAction.map_kind, match.?.action);
    try std.testing.expectEqual(@as(?i64, 1), match.?.activity_id);
    try std.testing.expectEqual(@as(?i64, 10), match.?.kind_id);
}

test "DuckDbRuleRepository returns null when no match" {
    const conn = try openInMemoryDb();
    var repo = DuckDbRuleRepository.init(conn, std.testing.allocator);

    try repo.addRule(.{
        .app_pattern = "Safari",
        .title_pattern = null,
        .activity_id = 1,
        .kind_id = 10,
    });

    const match = try repo.findMatch("Firefox", "Homepage");
    try std.testing.expect(match == null);
}

test "DuckDbRuleRepository matches by priority" {
    const conn = try openInMemoryDb();
    var repo = DuckDbRuleRepository.init(conn, std.testing.allocator);

    // Lower priority rule (should NOT match first)
    try repo.addRule(.{
        .app_pattern = "*",
        .title_pattern = null,
        .activity_id = 1,
        .kind_id = 1,
        .priority = 0,
    });

    // Higher priority rule (should match first)
    try repo.addRule(.{
        .app_pattern = "Code",
        .title_pattern = null,
        .activity_id = 2,
        .kind_id = 20,
        .priority = 100,
    });

    const match = try repo.findMatch("Code", "main.zig");
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(?i64, 2), match.?.activity_id);
    try std.testing.expectEqual(@as(?i64, 20), match.?.kind_id);
}

test "DuckDbRuleRepository matches glob patterns" {
    const conn = try openInMemoryDb();
    var repo = DuckDbRuleRepository.init(conn, std.testing.allocator);

    try repo.addRule(.{
        .app_pattern = "Code",
        .title_pattern = "*.zig",
        .activity_id = 5,
        .kind_id = 50,
    });

    const match1 = try repo.findMatch("Code", "main.zig");
    try std.testing.expect(match1 != null);
    try std.testing.expectEqual(@as(?i64, 50), match1.?.kind_id);

    const match2 = try repo.findMatch("Code", "main.rs");
    try std.testing.expect(match2 == null);
}

test "DuckDbRuleRepository works through interface" {
    const conn = try openInMemoryDb();
    var duck_repo = DuckDbRuleRepository.init(conn, std.testing.allocator);

    const repo = duck_repo.repository();

    try repo.addRule(.{
        .app_pattern = "Terminal",
        .title_pattern = null,
        .activity_id = 3,
        .kind_id = 30,
    });

    try std.testing.expectEqual(@as(i64, 1), try repo.getRuleCount());

    const match = try repo.findMatch("Terminal", "zsh");
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(?i64, 30), match.?.kind_id);
}

test "DuckDbRuleRepository skips global rules without context" {
    const conn = try openInMemoryDb();
    var repo = DuckDbRuleRepository.init(conn, std.testing.allocator);

    // Add a global rule
    try repo.addRule(.{
        .app_pattern = "Code",
        .title_pattern = null,
        .activity_id = 0, // Global rules don't use this directly
        .kind_id = 0,
        .priority = 100,
        .is_global = true,
        .kind_name = "Development",
    });

    // Add a non-global rule with lower priority
    try repo.addRule(.{
        .app_pattern = "Code",
        .title_pattern = null,
        .activity_id = 2,
        .kind_id = 20,
        .priority = 0,
    });

    // findMatch should skip the global rule and match the non-global one
    const match = try repo.findMatch("Code", "main.zig");
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(?i64, 2), match.?.activity_id);
    try std.testing.expectEqual(@as(?i64, 20), match.?.kind_id);
}

test "DuckDbRuleRepository returns follow_previous action" {
    const conn = try openInMemoryDb();
    var repo = DuckDbRuleRepository.init(conn, std.testing.allocator);

    try repo.addRule(.{
        .app_pattern = "Slack",
        .title_pattern = null,
        .activity_id = 0,
        .kind_id = 0,
        .priority = 50,
        .follow_previous = true,
    });

    const match = try repo.findMatch("Slack", "channel");
    try std.testing.expect(match != null);
    try std.testing.expectEqual(domain_rule.MatchAction.follow_previous, match.?.action);
    try std.testing.expectEqual(@as(?i64, null), match.?.activity_id);
    try std.testing.expectEqual(@as(?i64, null), match.?.kind_id);
}
