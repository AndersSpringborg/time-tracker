const std = @import("std");
const AppContext = @import("app_context").AppContext;
const Event = @import("domain_event").Event;

test "AppContext initializes with in-memory database" {
    const ctx = try AppContext.initInMemory(std.testing.allocator);
    defer ctx.deinit();

    // Verify we can access the use cases
    _ = ctx.trackEvent;
    _ = ctx.manageProject;
}

test "AppContext trackEvent use case works end-to-end" {
    const ctx = try AppContext.initInMemory(std.testing.allocator);
    defer ctx.deinit();

    // Add a rule first
    try ctx.ruleRepo.addRule(.{
        .app_pattern = "Safari",
        .title_pattern = null,
        .activity_id = 1,
        .kind_id = 10,
        .priority = 0,
    });

    // Track first event - this sets it as "last_event" in use case
    const event1 = Event{
        .timestamp_ms = 1000,
        .app_name = "Safari",
        .window_title = "Google",
        .wifi_ssid = "Home",
    };
    ctx.trackEvent.handle(event1);

    // Track second event - this saves event1 with computed duration
    const event2 = Event{
        .timestamp_ms = 3000,
        .app_name = "Terminal",
        .window_title = "bash",
        .wifi_ssid = "Home",
    };
    ctx.trackEvent.handle(event2);

    // Verify event was saved (first event gets saved when second arrives)
    try std.testing.expectEqual(@as(i64, 1), ctx.eventRepo.countEvents());

    // Verify rule was applied to the saved Safari event
    const last = ctx.eventRepo.getLastEvent();
    try std.testing.expect(last != null);
    try std.testing.expectEqual(@as(?i64, 1), last.?.activity_id);
    try std.testing.expectEqual(@as(?i64, 10), last.?.kind_id);
}

test "AppContext manageProject use case works end-to-end" {
    const ctx = try AppContext.initInMemory(std.testing.allocator);
    defer ctx.deinit();

    // Setup: create a project in the database
    const migrations = @import("migrations");
    const c = migrations.c;

    // Insert customer
    var result: c.duckdb_result = undefined;
    _ = c.duckdb_query(ctx.conn, "INSERT INTO customers (customer_id, name) VALUES (1, 'Test')", &result);
    c.duckdb_destroy_result(&result);

    // Insert project
    _ = c.duckdb_query(ctx.conn, "INSERT INTO projects (project_id, customer_id, name) VALUES (42, 1, 'Project')", &result);
    c.duckdb_destroy_result(&result);

    // Use the manage project use case
    try std.testing.expect(!(try ctx.manageProject.hasActiveProjects()));

    try ctx.manageProject.startProject(42);
    try std.testing.expect(try ctx.manageProject.hasActiveProjects());

    // Check project 42 is in active projects list
    const active_ids = try ctx.manageProject.getActiveProjects();
    defer ctx.manageProject.freeProjectIds(active_ids);
    try std.testing.expectEqual(@as(usize, 1), active_ids.len);
    try std.testing.expectEqual(@as(i64, 42), active_ids[0]);

    try ctx.manageProject.stopProject(42);
    try std.testing.expect(!(try ctx.manageProject.hasActiveProjects()));
}

test "AppContext tracks events with duration calculation" {
    const ctx = try AppContext.initInMemory(std.testing.allocator);
    defer ctx.deinit();

    // Track first event - stored as "last_event"
    const event1 = Event{
        .timestamp_ms = 1000,
        .app_name = "Code",
        .window_title = "main.zig",
        .wifi_ssid = "",
    };
    ctx.trackEvent.handle(event1);

    // No events saved yet (first event is pending)
    try std.testing.expectEqual(@as(i64, 0), ctx.eventRepo.countEvents());

    // Track second event - saves first with duration = 3500 - 1000 = 2500ms
    const event2 = Event{
        .timestamp_ms = 3500,
        .app_name = "Safari",
        .window_title = "Google",
        .wifi_ssid = "",
    };
    ctx.trackEvent.handle(event2);

    // First event now saved
    try std.testing.expectEqual(@as(i64, 1), ctx.eventRepo.countEvents());

    // Third event saves second
    const event3 = Event{
        .timestamp_ms = 5000,
        .app_name = "Terminal",
        .window_title = "zsh",
        .wifi_ssid = "",
    };
    ctx.trackEvent.handle(event3);

    // Now have 2 saved events
    try std.testing.expectEqual(@as(i64, 2), ctx.eventRepo.countEvents());
}
