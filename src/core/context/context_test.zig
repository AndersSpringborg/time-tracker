const std = @import("std");
const context = @import("context");
const ProjectContext = context.ProjectContext;
const ProjectAssignment = context.ProjectAssignment;
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

    // Insert test project data
    var result: c.duckdb_result = undefined;
    const setup_sql =
        \\INSERT INTO customers (customer_id, name) VALUES (1, 'Test Customer');
        \\INSERT INTO projects (project_id, customer_id, name) VALUES (100, 1, 'Project Alpha');
        \\INSERT INTO projects (project_id, customer_id, name) VALUES (200, 1, 'Project Beta');
        \\INSERT INTO projects (project_id, customer_id, name) VALUES (300, 1, 'Project Gamma');
    ;
    if (c.duckdb_query(conn, setup_sql, &result) == c.DuckDBError) {
        c.duckdb_destroy_result(&result);
        return error.SetupFailed;
    }
    c.duckdb_destroy_result(&result);

    return conn;
}

// Test 1: Initialize ProjectContext
test "ProjectContext.init succeeds" {
    const conn = try openTestDb();
    var ctx = ProjectContext.init(conn, std.testing.allocator);
    _ = &ctx;
}

// Test 2: addProject inserts a project assignment
test "ProjectContext.addProject creates assignment" {
    const conn = try openTestDb();
    var ctx = ProjectContext.init(conn, std.testing.allocator);

    try ctx.addProject(100);

    const active = try ctx.getActiveProjects();
    defer std.testing.allocator.free(active);

    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqual(@as(i64, 100), active[0].project_id);
    try std.testing.expect(active[0].ended_at == null);
}

// Test 3: addProject is idempotent - adding same project twice does not create duplicate
test "ProjectContext.addProject is idempotent" {
    const conn = try openTestDb();
    var ctx = ProjectContext.init(conn, std.testing.allocator);

    try ctx.addProject(100);
    try ctx.addProject(100); // Should not create duplicate

    const active = try ctx.getActiveProjects();
    defer std.testing.allocator.free(active);

    try std.testing.expectEqual(@as(usize, 1), active.len);
}

// Test 4: endProject sets ended_at timestamp
test "ProjectContext.endProject sets ended_at" {
    const conn = try openTestDb();
    var ctx = ProjectContext.init(conn, std.testing.allocator);

    try ctx.addProject(100);
    try ctx.endProject(100);

    const active = try ctx.getActiveProjects();
    defer std.testing.allocator.free(active);

    // No active projects after ending
    try std.testing.expectEqual(@as(usize, 0), active.len);
}

// Test 5: getActiveProjects returns only projects with null ended_at
test "ProjectContext.getActiveProjects filters by ended_at" {
    const conn = try openTestDb();
    var ctx = ProjectContext.init(conn, std.testing.allocator);

    try ctx.addProject(100);
    try ctx.addProject(200);
    try ctx.endProject(100);

    const active = try ctx.getActiveProjects();
    defer std.testing.allocator.free(active);

    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqual(@as(i64, 200), active[0].project_id);
}

// Test 6: getActiveProjectIds returns just the IDs
test "ProjectContext.getActiveProjectIds returns IDs only" {
    const conn = try openTestDb();
    var ctx = ProjectContext.init(conn, std.testing.allocator);

    try ctx.addProject(100);
    try ctx.addProject(200);

    const ids = try ctx.getActiveProjectIds();
    defer std.testing.allocator.free(ids);

    try std.testing.expectEqual(@as(usize, 2), ids.len);
    // Check both IDs are present (order may vary)
    const has_100 = ids[0] == 100 or ids[1] == 100;
    const has_200 = ids[0] == 200 or ids[1] == 200;
    try std.testing.expect(has_100);
    try std.testing.expect(has_200);
}

// Test 7: hasActiveProjects returns true when projects exist
test "ProjectContext.hasActiveProjects returns correct state" {
    const conn = try openTestDb();
    var ctx = ProjectContext.init(conn, std.testing.allocator);

    try std.testing.expect(!try ctx.hasActiveProjects());

    try ctx.addProject(100);
    try std.testing.expect(try ctx.hasActiveProjects());

    try ctx.endProject(100);
    try std.testing.expect(!try ctx.hasActiveProjects());
}

// Test 8: endAllProjects ends all active projects
test "ProjectContext.endAllProjects ends all active" {
    const conn = try openTestDb();
    var ctx = ProjectContext.init(conn, std.testing.allocator);

    try ctx.addProject(100);
    try ctx.addProject(200);
    try ctx.addProject(300);

    try ctx.endAllProjects();

    const active = try ctx.getActiveProjects();
    defer std.testing.allocator.free(active);

    try std.testing.expectEqual(@as(usize, 0), active.len);
}

// Test 9: isProjectActive checks specific project
test "ProjectContext.isProjectActive checks specific project" {
    const conn = try openTestDb();
    var ctx = ProjectContext.init(conn, std.testing.allocator);

    try std.testing.expect(!try ctx.isProjectActive(100));

    try ctx.addProject(100);
    try std.testing.expect(try ctx.isProjectActive(100));
    try std.testing.expect(!try ctx.isProjectActive(200));

    try ctx.endProject(100);
    try std.testing.expect(!try ctx.isProjectActive(100));
}
