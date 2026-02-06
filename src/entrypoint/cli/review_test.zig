const std = @import("std");
const testing = std.testing;
const review = @import("review");
const migrations = @import("migrations");
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

    // Run migrations
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

fn insertTestHierarchy(conn: c.duckdb_connection) !void {
    // Insert test customers
    try execQuery(conn, "INSERT INTO customers (customer_id, name) VALUES (1, 'Acme Corp'), (2, 'Beta Inc')");

    // Insert test projects
    try execQuery(conn, "INSERT INTO projects (project_id, customer_id, name) VALUES (10, 1, 'Website Redesign'), (11, 1, 'Mobile App'), (20, 2, 'Cloud Migration')");

    // Insert test phases
    try execQuery(conn, "INSERT INTO phases (phase_id, project_id, name) VALUES (100, 10, 'Design'), (101, 10, 'Development'), (200, 20, 'Planning')");

    // Insert test activities
    try execQuery(conn, "INSERT INTO activities (activity_id, phase_id, name) VALUES (1000, 100, 'Billable'), (1001, 100, 'Not billable'), (2000, 200, 'Billable')");

    // Insert test kinds
    try execQuery(conn, "INSERT INTO kinds (kind_id, activity_id, name, billable) VALUES (10000, 1000, 'Coding', true), (10001, 1000, 'Review', true), (10002, 1001, 'Meetings', false), (20000, 2000, 'Analysis', true)");
}

fn insertTestEvents(conn: c.duckdb_connection) !void {
    // Insert some unmapped events
    try execQuery(conn, "INSERT INTO events (timestamp_ms, app_name, window_title, wifi_ssid, duration_ms) VALUES (1000, 'IntelliJ IDEA', 'MyProject - Main.java', 'Office', 3600000)");
    try execQuery(conn, "INSERT INTO events (timestamp_ms, app_name, window_title, wifi_ssid, duration_ms) VALUES (2000, 'Chrome', 'Jira - Sprint Board', 'Office', 1800000)");
    try execQuery(conn, "INSERT INTO events (timestamp_ms, app_name, window_title, wifi_ssid, duration_ms) VALUES (3000, 'Slack', 'team-engineering', 'Home', 900000)");

    // Insert a mapped event (should not appear in unmapped list)
    try execQuery(conn, "INSERT INTO events (timestamp_ms, app_name, window_title, wifi_ssid, duration_ms, activity_id, kind_id) VALUES (4000, 'IntelliJ IDEA', 'OtherProject', 'Office', 600000, 1000, 10000)");
}

test "getUnmappedEvents returns only unmapped events" {
    const conn = try setupTestDb();
    try insertTestHierarchy(conn);
    try insertTestEvents(conn);

    var reviewer = review.Reviewer.init(conn, testing.allocator);
    const events = try reviewer.getUnmappedEvents();
    defer testing.allocator.free(events);

    try testing.expectEqual(@as(usize, 3), events.len);

    // Events are ordered by timestamp DESC (newest first)
    // Slack (timestamp 3000) should be first
    try testing.expectEqualStrings("Slack", events[0].app_name);
    try testing.expectEqualStrings("team-engineering", events[0].window_title);
    try testing.expectEqual(@as(i64, 900000), events[0].duration_ms);

    // IntelliJ (timestamp 1000) should be last
    try testing.expectEqualStrings("IntelliJ IDEA", events[2].app_name);
}

test "searchCustomers returns matching customers" {
    const conn = try setupTestDb();
    try insertTestHierarchy(conn);

    var reviewer = review.Reviewer.init(conn, testing.allocator);

    // Search for "acme"
    const results = try reviewer.searchCustomers("acme");
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("Acme Corp", results[0].name);
}

test "searchCustomers is case insensitive" {
    const conn = try setupTestDb();
    try insertTestHierarchy(conn);

    var reviewer = review.Reviewer.init(conn, testing.allocator);

    // Search with different case
    const results = try reviewer.searchCustomers("BETA");
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("Beta Inc", results[0].name);
}

test "getProjectsForCustomer returns correct projects" {
    const conn = try setupTestDb();
    try insertTestHierarchy(conn);

    var reviewer = review.Reviewer.init(conn, testing.allocator);

    const projects = try reviewer.getProjectsForCustomer(1);
    defer testing.allocator.free(projects);

    try testing.expectEqual(@as(usize, 2), projects.len);
}

test "getPhasesForProject returns correct phases" {
    const conn = try setupTestDb();
    try insertTestHierarchy(conn);

    var reviewer = review.Reviewer.init(conn, testing.allocator);

    const phases = try reviewer.getPhasesForProject(10);
    defer testing.allocator.free(phases);

    try testing.expectEqual(@as(usize, 2), phases.len);
}

test "getActivitiesForPhase returns correct activities" {
    const conn = try setupTestDb();
    try insertTestHierarchy(conn);

    var reviewer = review.Reviewer.init(conn, testing.allocator);

    const activities = try reviewer.getActivitiesForPhase(100);
    defer testing.allocator.free(activities);

    try testing.expectEqual(@as(usize, 2), activities.len);
}

test "getKindsForActivity returns correct kinds" {
    const conn = try setupTestDb();
    try insertTestHierarchy(conn);

    var reviewer = review.Reviewer.init(conn, testing.allocator);

    const kinds = try reviewer.getKindsForActivity(1000);
    defer testing.allocator.free(kinds);

    try testing.expectEqual(@as(usize, 2), kinds.len);
}

test "mapEvent updates event with activity and kind" {
    const conn = try setupTestDb();
    try insertTestHierarchy(conn);
    try insertTestEvents(conn);

    var reviewer = review.Reviewer.init(conn, testing.allocator);

    // Get unmapped events first
    const events_before = try reviewer.getUnmappedEvents();
    defer testing.allocator.free(events_before);
    const event_id = events_before[0].id;

    // Map the event
    try reviewer.mapEvent(event_id, 1000, 10000, true);

    // Verify it's now mapped
    const events_after = try reviewer.getUnmappedEvents();
    defer testing.allocator.free(events_after);

    // Should have one less unmapped event
    try testing.expectEqual(@as(usize, 2), events_after.len);
}

test "searchFullHierarchy returns concatenated path" {
    const conn = try setupTestDb();
    try insertTestHierarchy(conn);

    var reviewer = review.Reviewer.init(conn, testing.allocator);

    // Search across the entire hierarchy
    const results = try reviewer.searchFullHierarchy("coding");
    defer {
        for (results) |r| {
            testing.allocator.free(r.display_path);
        }
        testing.allocator.free(results);
    }

    try testing.expectEqual(@as(usize, 1), results.len);
    // Should show: "Acme Corp > Website Redesign > Design > Billable > Coding"
    try testing.expect(std.mem.containsAtLeast(u8, results[0].display_path, 1, "Acme Corp"));
    try testing.expect(std.mem.containsAtLeast(u8, results[0].display_path, 1, "Coding"));
}

test "getUnmappedEventsForDateFiltered excludes events under 2s" {
    const conn = try setupTestDb();
    try insertTestHierarchy(conn);

    try execQuery(conn, "INSERT INTO events (timestamp_ms, app_name, window_title, wifi_ssid, duration_ms) VALUES (3600000, 'Code', 'short', 'Office', 1500)");
    try execQuery(conn, "INSERT INTO events (timestamp_ms, app_name, window_title, wifi_ssid, duration_ms) VALUES (3601000, 'Code', 'long', 'Office', 2500)");

    var reviewer = review.Reviewer.init(conn, testing.allocator);
    const dates = try reviewer.getDatesWithUnmappedEvents();
    defer testing.allocator.free(dates);
    try testing.expect(dates.len > 0);

    const events = try reviewer.getUnmappedEventsForDateFiltered(dates[0].slice(), 2000);
    defer testing.allocator.free(events);

    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expect(events[0].duration_ms >= 2000);
}

test "getHourlyUnmappedSummaryForDate aggregates counts and duration" {
    const conn = try setupTestDb();
    try insertTestHierarchy(conn);

    try execQuery(conn, "INSERT INTO events (timestamp_ms, app_name, window_title, wifi_ssid, duration_ms) VALUES (3600000, 'Code', 'A', 'Office', 10000)");
    try execQuery(conn, "INSERT INTO events (timestamp_ms, app_name, window_title, wifi_ssid, duration_ms) VALUES (3602000, 'Code', 'B', 'Office', 20000)");
    try execQuery(conn, "INSERT INTO events (timestamp_ms, app_name, window_title, wifi_ssid, duration_ms) VALUES (7200000, 'Slack', 'C', 'Office', 30000)");

    var reviewer = review.Reviewer.init(conn, testing.allocator);
    const dates = try reviewer.getDatesWithUnmappedEvents();
    defer testing.allocator.free(dates);
    try testing.expect(dates.len > 0);

    const buckets = try reviewer.getHourlyUnmappedSummaryForDate(dates[0].slice(), 0);
    defer testing.allocator.free(buckets);

    try testing.expectEqual(@as(usize, 2), buckets.len);

    var total_count: i64 = 0;
    var total_duration: i64 = 0;
    for (buckets) |bucket| {
        total_count += bucket.event_count;
        total_duration += bucket.total_duration_ms;
    }

    try testing.expectEqual(@as(i64, 3), total_count);
    try testing.expectEqual(@as(i64, 60000), total_duration);
}

test "discardEvent marks only one event manually mapped" {
    const conn = try setupTestDb();
    try insertTestHierarchy(conn);
    try insertTestEvents(conn);

    var reviewer = review.Reviewer.init(conn, testing.allocator);

    const before = try reviewer.getUnmappedEvents();
    defer testing.allocator.free(before);
    try testing.expectEqual(@as(usize, 3), before.len);

    try reviewer.discardEvent(before[0].id);

    const after = try reviewer.getUnmappedEvents();
    defer testing.allocator.free(after);
    try testing.expectEqual(@as(usize, 2), after.len);
}
