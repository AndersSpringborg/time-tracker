const std = @import("std");
const suggestions = @import("suggestions");
const SuggestionEngine = suggestions.SuggestionEngine;
const Suggestion = suggestions.Suggestion;
const migrations = @import("migrations");
const Migrator = migrations.Migrator;
const c = migrations.c;

fn openTestDb() !c.duckdb_connection {
    var db: c.duckdb_database = undefined;
    var conn: c.duckdb_connection = undefined;

    if (c.duckdb_open(":memory:", &db) == c.DuckDBError) {
        return error.OpenFailed;
    }

    if (c.duckdb_connect(db, &conn) == c.DuckDBError) {
        c.duckdb_close(&db);
        return error.ConnectFailed;
    }

    // Run migrations to set up schema
    var migrator = try Migrator.init(conn);
    try migrator.run();

    // Insert test hierarchy
    var result: c.duckdb_result = undefined;
    const setup_sql =
        \\INSERT INTO customers (customer_id, name) VALUES (1, 'Trifork');
        \\INSERT INTO projects (project_id, customer_id, name) VALUES (100, 1, 'Academy');
        \\INSERT INTO projects (project_id, customer_id, name) VALUES (200, 1, 'Internal');
        \\INSERT INTO phases (phase_id, project_id, name) VALUES (1000, 100, 'Development');
        \\INSERT INTO phases (phase_id, project_id, name) VALUES (2000, 200, 'Admin');
        \\INSERT INTO activities (activity_id, phase_id, name) VALUES (10000, 1000, 'Coding');
        \\INSERT INTO activities (activity_id, phase_id, name) VALUES (20000, 2000, 'Meetings');
        \\INSERT INTO kinds (kind_id, activity_id, name, billable) VALUES (100000, 10000, 'Feature', true);
        \\INSERT INTO kinds (kind_id, activity_id, name, billable) VALUES (200000, 20000, 'Internal', false);
    ;
    if (c.duckdb_query(conn, setup_sql, &result) == c.DuckDBError) {
        c.duckdb_destroy_result(&result);
        return error.SetupFailed;
    }
    c.duckdb_destroy_result(&result);

    return conn;
}

fn setupRulesAndEvents(conn: c.duckdb_connection) !void {
    var result: c.duckdb_result = undefined;
    const sql =
        \\INSERT INTO mapping_rules (id, priority, app_pattern, title_pattern, activity_id, kind_id)
        \\VALUES 
        \\  (1, 10, 'IntelliJ*', '*time-tracker*', 10000, 100000),
        \\  (2, 5, 'Firefox', 'JIRA*', 20000, 200000),
        \\  (3, 1, 'Slack', '*', 20000, 200000);
        \\
        \\INSERT INTO events (id, timestamp_ms, app_name, window_title, duration_ms, activity_id, kind_id)
        \\VALUES 
        \\  (1, 1700000000000, 'IntelliJ IDEA', 'time-tracker - main.zig', 3600000, 10000, 100000),
        \\  (2, 1700000100000, 'IntelliJ IDEA', 'time-tracker - build.zig', 1800000, 10000, 100000),
        \\  (3, 1700000200000, 'Firefox', 'JIRA - Sprint Planning', 900000, 20000, 200000);
        \\
        \\INSERT INTO project_assignments (id, project_id, started_at, ended_at) 
        \\VALUES (1, 100, current_timestamp, NULL);
    ;
    if (c.duckdb_query(conn, sql, &result) == c.DuckDBError) {
        c.duckdb_destroy_result(&result);
        return error.SetupFailed;
    }
    c.duckdb_destroy_result(&result);
}

// Test 1: SuggestionEngine initializes
test "SuggestionEngine.init succeeds" {
    const conn = try openTestDb();
    var engine = SuggestionEngine.init(conn, std.testing.allocator);
    _ = &engine;
}

// Test 2: Get suggestions based on matching rules
test "SuggestionEngine.getSuggestions returns matching rules" {
    const conn = try openTestDb();
    try setupRulesAndEvents(conn);

    var engine = SuggestionEngine.init(conn, std.testing.allocator);
    const result = try engine.getSuggestions("IntelliJ IDEA", "time-tracker - test.zig", 3);
    defer {
        for (result) |s| {
            std.testing.allocator.free(s.display_path);
        }
        std.testing.allocator.free(result);
    }

    // Should find the IntelliJ rule
    try std.testing.expect(result.len >= 1);
    // First result should be the best match
    try std.testing.expectEqual(@as(i64, 10000), result[0].activity_id);
}

// Test 3: Returns empty when no matches
test "SuggestionEngine.getSuggestions returns empty for no match" {
    const conn = try openTestDb();
    try setupRulesAndEvents(conn);

    var engine = SuggestionEngine.init(conn, std.testing.allocator);
    const result = try engine.getSuggestions("UnknownApp", "Random Title", 3);
    defer {
        for (result) |s| {
            std.testing.allocator.free(s.display_path);
        }
        std.testing.allocator.free(result);
    }

    // This test checks that rules with wildcards don't match arbitrary input
    // The Slack rule has "*" title pattern which would match anything, but app must match "Slack"
    // None of our rules should match "UnknownApp"
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

// Test 4: Active projects boost score
test "SuggestionEngine.getSuggestions boosts active projects" {
    const conn = try openTestDb();
    try setupRulesAndEvents(conn);

    var engine = SuggestionEngine.init(conn, std.testing.allocator);
    const result = try engine.getSuggestions("IntelliJ IDEA", "time-tracker - main.zig", 3);
    defer {
        for (result) |s| {
            std.testing.allocator.free(s.display_path);
        }
        std.testing.allocator.free(result);
    }

    // Project 100 (Academy) is active, so it should be boosted
    try std.testing.expect(result.len >= 1);
    // The suggestion should indicate it's from an active project
    try std.testing.expect(result[0].is_active_project);
}

// Test 5: Respects max results
test "SuggestionEngine.getSuggestions respects max_results" {
    const conn = try openTestDb();
    try setupRulesAndEvents(conn);

    var engine = SuggestionEngine.init(conn, std.testing.allocator);
    const result = try engine.getSuggestions("Slack", "any channel", 2);
    defer {
        for (result) |s| {
            std.testing.allocator.free(s.display_path);
        }
        std.testing.allocator.free(result);
    }

    try std.testing.expect(result.len <= 2);
}

// Test 6: Display path is populated
test "SuggestionEngine.getSuggestions populates display_path" {
    const conn = try openTestDb();
    try setupRulesAndEvents(conn);

    var engine = SuggestionEngine.init(conn, std.testing.allocator);
    const result = try engine.getSuggestions("IntelliJ IDEA", "time-tracker - main.zig", 3);
    defer {
        for (result) |s| {
            std.testing.allocator.free(s.display_path);
        }
        std.testing.allocator.free(result);
    }

    try std.testing.expect(result.len >= 1);
    // Display path should contain the hierarchy
    try std.testing.expect(std.mem.indexOf(u8, result[0].display_path, "Trifork") != null);
    try std.testing.expect(std.mem.indexOf(u8, result[0].display_path, "Academy") != null);
}
