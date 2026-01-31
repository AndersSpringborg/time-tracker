const std = @import("std");
const rules = @import("rules");
const RulesEngine = rules.RulesEngine;
const Rule = rules.Rule;
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

// Test 1: Glob pattern matching - exact match
test "globMatch matches exact strings" {
    try std.testing.expect(rules.globMatch("Firefox", "Firefox"));
    try std.testing.expect(!rules.globMatch("Firefox", "Chrome"));
}

// Test 2: Glob pattern matching - wildcard at end
test "globMatch matches wildcard at end" {
    try std.testing.expect(rules.globMatch("IntelliJ*", "IntelliJ IDEA"));
    try std.testing.expect(rules.globMatch("IntelliJ*", "IntelliJ"));
    try std.testing.expect(!rules.globMatch("IntelliJ*", "PyCharm"));
}

// Test 3: Glob pattern matching - wildcard at start
test "globMatch matches wildcard at start" {
    try std.testing.expect(rules.globMatch("*money*", "young-money-app"));
    try std.testing.expect(rules.globMatch("*money*", "&Money ApS"));
    try std.testing.expect(!rules.globMatch("*money*", "other-project"));
}

// Test 4: Glob pattern matching - case insensitive
test "globMatch is case insensitive" {
    try std.testing.expect(rules.globMatch("*MONEY*", "young-money-app"));
    try std.testing.expect(rules.globMatch("*money*", "MONEY-PROJECT"));
}

// Test 5: Add rule to database
test "RulesEngine adds rule to database" {
    const conn = try openInMemoryDb();
    try setupDb(conn);

    var engine = RulesEngine.init(conn, std.testing.allocator);

    try engine.addRule(.{
        .app_pattern = "IntelliJ*",
        .title_pattern = "*money*",
        .activity_id = 12345,
        .kind_id = 20,
        .priority = 10,
    });

    const rule_count = try engine.getRuleCount();
    try std.testing.expectEqual(@as(i64, 1), rule_count);
}

// Test 6: List rules from database
test "RulesEngine lists rules" {
    const conn = try openInMemoryDb();
    try setupDb(conn);

    var engine = RulesEngine.init(conn, std.testing.allocator);

    try engine.addRule(.{
        .app_pattern = "Firefox",
        .title_pattern = null,
        .activity_id = 100,
        .kind_id = 20,
        .priority = 5,
    });

    try engine.addRule(.{
        .app_pattern = "Chrome",
        .title_pattern = null,
        .activity_id = 200,
        .kind_id = 20,
        .priority = 10,
    });

    const fetched_rules = try engine.listRules();
    defer engine.allocator.free(fetched_rules);

    try std.testing.expectEqual(@as(usize, 2), fetched_rules.len);
    // Should be sorted by priority descending
    try std.testing.expectEqual(@as(i32, 10), fetched_rules[0].priority);
    try std.testing.expectEqual(@as(i32, 5), fetched_rules[1].priority);
}

// Test 7: Delete rule from database
test "RulesEngine deletes rule" {
    const conn = try openInMemoryDb();
    try setupDb(conn);

    var engine = RulesEngine.init(conn, std.testing.allocator);

    try engine.addRule(.{
        .app_pattern = "Firefox",
        .title_pattern = null,
        .activity_id = 100,
        .kind_id = 20,
        .priority = 5,
    });

    const rules_before = try engine.listRules();
    defer engine.allocator.free(rules_before);
    try std.testing.expectEqual(@as(usize, 1), rules_before.len);

    try engine.deleteRule(rules_before[0].id);

    const count = try engine.getRuleCount();
    try std.testing.expectEqual(@as(i64, 0), count);
}

// Test 8: Find matching rule for event
test "RulesEngine finds matching rule" {
    const conn = try openInMemoryDb();
    try setupDb(conn);

    var engine = RulesEngine.init(conn, std.testing.allocator);

    try engine.addRule(.{
        .app_pattern = "IntelliJ*",
        .title_pattern = "*money*",
        .activity_id = 12345,
        .kind_id = 20,
        .priority = 10,
    });

    const match = try engine.findMatch("IntelliJ IDEA", "young-money-service/main.zig");
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(i64, 12345), match.?.activity_id);
}

// Test 9: No match when patterns don't match
test "RulesEngine returns null when no match" {
    const conn = try openInMemoryDb();
    try setupDb(conn);

    var engine = RulesEngine.init(conn, std.testing.allocator);

    try engine.addRule(.{
        .app_pattern = "IntelliJ*",
        .title_pattern = "*money*",
        .activity_id = 12345,
        .kind_id = 20,
        .priority = 10,
    });

    const match = try engine.findMatch("Firefox", "google.com");
    try std.testing.expect(match == null);
}

// Test 10: Higher priority rule wins
test "RulesEngine higher priority wins" {
    const conn = try openInMemoryDb();
    try setupDb(conn);

    var engine = RulesEngine.init(conn, std.testing.allocator);

    // Low priority rule
    try engine.addRule(.{
        .app_pattern = "IntelliJ*",
        .title_pattern = null,
        .activity_id = 100,
        .kind_id = 20,
        .priority = 5,
    });

    // High priority rule (more specific)
    try engine.addRule(.{
        .app_pattern = "IntelliJ*",
        .title_pattern = "*money*",
        .activity_id = 200,
        .kind_id = 20,
        .priority = 10,
    });

    const match = try engine.findMatch("IntelliJ IDEA", "money-service/main.zig");
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(i64, 200), match.?.activity_id);
}

// Test 11: Null pattern means "any"
test "RulesEngine null pattern matches any" {
    const conn = try openInMemoryDb();
    try setupDb(conn);

    var engine = RulesEngine.init(conn, std.testing.allocator);

    try engine.addRule(.{
        .app_pattern = "Slack",
        .title_pattern = null, // Any title
        .activity_id = 300,
        .kind_id = 20,
        .priority = 5,
    });

    const match = try engine.findMatch("Slack", "Any window title here");
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(i64, 300), match.?.activity_id);
}
