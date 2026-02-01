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

// Test 12: Global rule is skipped without project context
test "Global rule skipped without project context" {
    const conn = try openInMemoryDb();
    try setupDb(conn);

    var engine = RulesEngine.init(conn, std.testing.allocator);

    // Add a global rule
    try engine.addRule(.{
        .app_pattern = "Chrome",
        .title_pattern = null,
        .activity_id = 0,
        .kind_id = 0,
        .priority = 10,
        .is_global = true,
        .kind_name = "Distraction",
    });

    // Without project context, global rule should be skipped
    const match = try engine.findMatch("Chrome", "facebook.com");
    try std.testing.expect(match == null);
}

// Test 13: Global rule resolves kind in project context
test "Global rule resolves kind in project context" {
    const conn = try openInMemoryDb();
    try setupDb(conn);

    // Set up a project hierarchy with a "Distraction" kind
    try insertTestHierarchy(conn);

    var engine = RulesEngine.init(conn, std.testing.allocator);

    // Add a global rule
    try engine.addRule(.{
        .app_pattern = "Chrome",
        .title_pattern = "*facebook*",
        .activity_id = 0,
        .kind_id = 0,
        .priority = 10,
        .is_global = true,
        .kind_name = "Distraction",
    });

    // With project context, global rule should resolve "Distraction" in project 1
    const match = try engine.findMatchWithContext("Chrome", "facebook.com - News Feed", 1);
    try std.testing.expect(match != null);
    // The resolved kind_id should be 2 (from test hierarchy)
    try std.testing.expectEqual(@as(i64, 2), match.?.kind_id);
}

// Test 14: Global rule skipped if kind name not found in project
test "Global rule skipped if kind not in project" {
    const conn = try openInMemoryDb();
    try setupDb(conn);

    // Set up a project hierarchy (no "NonExistent" kind)
    try insertTestHierarchy(conn);

    var engine = RulesEngine.init(conn, std.testing.allocator);

    // Add a global rule for a kind that doesn't exist
    try engine.addRule(.{
        .app_pattern = "Chrome",
        .title_pattern = null,
        .activity_id = 0,
        .kind_id = 0,
        .priority = 10,
        .is_global = true,
        .kind_name = "NonExistent",
    });

    // Global rule should be skipped since kind doesn't exist
    const match = try engine.findMatchWithContext("Chrome", "google.com", 1);
    try std.testing.expect(match == null);
}

// Test 15: Global rule falls through to regular rule
test "Global rule falls through to next rule" {
    const conn = try openInMemoryDb();
    try setupDb(conn);

    try insertTestHierarchy(conn);

    var engine = RulesEngine.init(conn, std.testing.allocator);

    // High priority global rule for nonexistent kind (will be skipped)
    try engine.addRule(.{
        .app_pattern = "Chrome",
        .title_pattern = null,
        .activity_id = 0,
        .kind_id = 0,
        .priority = 20,
        .is_global = true,
        .kind_name = "NonExistent",
    });

    // Lower priority regular rule (should match)
    try engine.addRule(.{
        .app_pattern = "Chrome",
        .title_pattern = null,
        .activity_id = 1,
        .kind_id = 1,
        .priority = 5,
    });

    // Global rule skipped, falls through to regular rule
    const match = try engine.findMatchWithContext("Chrome", "google.com", 1);
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(i64, 1), match.?.kind_id);
}

fn insertTestHierarchy(conn: c.duckdb_connection) !void {
    // Create a simple hierarchy: Customer -> Project -> Phase -> Activity -> Kind
    const setup_sql =
        \\INSERT INTO customers (customer_id, name) VALUES (1, 'Test Customer');
        \\INSERT INTO projects (project_id, customer_id, name) VALUES (1, 1, 'Test Project');
        \\INSERT INTO phases (phase_id, project_id, name) VALUES (1, 1, 'Development');
        \\INSERT INTO activities (activity_id, phase_id, name) VALUES (1, 1, 'Coding');
        \\INSERT INTO kinds (kind_id, activity_id, name, billable) VALUES (1, 1, 'Productive', true);
        \\INSERT INTO kinds (kind_id, activity_id, name, billable) VALUES (2, 1, 'Distraction', false);
    ;

    var result: c.duckdb_result = undefined;
    if (c.duckdb_query(conn, setup_sql, &result) == c.DuckDBError) {
        return error.QueryFailed;
    }
    c.duckdb_destroy_result(&result);
}
