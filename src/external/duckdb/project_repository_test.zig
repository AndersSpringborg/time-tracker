const std = @import("std");
const DuckDbProjectRepository = @import("duckdb_project_repository").DuckDbProjectRepository;
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

/// Insert test data: customer -> project hierarchy
fn setupTestProject(conn: c.duckdb_connection, project_id: i64) !void {
    // Insert customer
    var result: c.duckdb_result = undefined;
    if (c.duckdb_query(conn, "INSERT INTO customers (customer_id, name) VALUES (1, 'Test Customer') ON CONFLICT DO NOTHING", &result) == c.DuckDBError) {
        return error.SetupFailed;
    }
    c.duckdb_destroy_result(&result);

    // Insert project with the given ID
    var stmt: c.duckdb_prepared_statement = undefined;
    if (c.duckdb_prepare(conn, "INSERT INTO projects (project_id, customer_id, name) VALUES (?, 1, 'Test Project') ON CONFLICT DO NOTHING", &stmt) == c.DuckDBError) {
        return error.SetupFailed;
    }
    defer c.duckdb_destroy_prepare(&stmt);

    _ = c.duckdb_bind_int64(stmt, 1, project_id);

    var result2: c.duckdb_result = undefined;
    if (c.duckdb_execute_prepared(stmt, &result2) == c.DuckDBError) {
        c.duckdb_destroy_result(&result2);
        return error.SetupFailed;
    }
    c.duckdb_destroy_result(&result2);
}

test "DuckDbProjectRepository adds and checks active projects" {
    const conn = try openInMemoryDb();
    var repo = DuckDbProjectRepository.init(conn, std.testing.allocator);

    // Setup test project
    try setupTestProject(conn, 1);
    try setupTestProject(conn, 2);

    // Initially no active projects
    try std.testing.expect(!(try repo.hasActiveProjects()));
    try std.testing.expect(!(try repo.isProjectActive(1)));

    // Add a project
    try repo.addProject(1);
    try std.testing.expect(try repo.hasActiveProjects());
    try std.testing.expect(try repo.isProjectActive(1));
    try std.testing.expect(!(try repo.isProjectActive(2)));
}

test "DuckDbProjectRepository addProject is idempotent" {
    const conn = try openInMemoryDb();
    var repo = DuckDbProjectRepository.init(conn, std.testing.allocator);

    try setupTestProject(conn, 1);

    try repo.addProject(1);
    try repo.addProject(1); // Adding again should be a no-op

    const ids = try repo.getActiveProjectIds();
    defer repo.freeProjectIds(ids);

    try std.testing.expectEqual(@as(usize, 1), ids.len);
}

test "DuckDbProjectRepository ends specific project" {
    const conn = try openInMemoryDb();
    var repo = DuckDbProjectRepository.init(conn, std.testing.allocator);

    try setupTestProject(conn, 1);
    try setupTestProject(conn, 2);

    try repo.addProject(1);
    try repo.addProject(2);

    try std.testing.expect(try repo.isProjectActive(1));
    try std.testing.expect(try repo.isProjectActive(2));

    try repo.endProject(1);

    try std.testing.expect(!(try repo.isProjectActive(1)));
    try std.testing.expect(try repo.isProjectActive(2));
}

test "DuckDbProjectRepository ends all projects" {
    const conn = try openInMemoryDb();
    var repo = DuckDbProjectRepository.init(conn, std.testing.allocator);

    try setupTestProject(conn, 1);
    try setupTestProject(conn, 2);
    try setupTestProject(conn, 3);

    try repo.addProject(1);
    try repo.addProject(2);
    try repo.addProject(3);

    try std.testing.expect(try repo.hasActiveProjects());

    try repo.endAllProjects();

    try std.testing.expect(!(try repo.hasActiveProjects()));
}

test "DuckDbProjectRepository getActiveProjectIds returns correct IDs" {
    const conn = try openInMemoryDb();
    var repo = DuckDbProjectRepository.init(conn, std.testing.allocator);

    try setupTestProject(conn, 10);
    try setupTestProject(conn, 20);

    try repo.addProject(10);
    try repo.addProject(20);

    const ids = try repo.getActiveProjectIds();
    defer repo.freeProjectIds(ids);

    try std.testing.expectEqual(@as(usize, 2), ids.len);

    // Check both IDs are present (order may vary)
    var found_10 = false;
    var found_20 = false;
    for (ids) |id| {
        if (id == 10) found_10 = true;
        if (id == 20) found_20 = true;
    }
    try std.testing.expect(found_10);
    try std.testing.expect(found_20);
}

test "DuckDbProjectRepository works through interface" {
    const conn = try openInMemoryDb();
    var duck_repo = DuckDbProjectRepository.init(conn, std.testing.allocator);

    try setupTestProject(conn, 5);

    const repo = duck_repo.repository();

    try std.testing.expect(!(try repo.hasActiveProjects()));

    try repo.addProject(5);
    try std.testing.expect(try repo.hasActiveProjects());
    try std.testing.expect(try repo.isProjectActive(5));

    try repo.endProject(5);
    try std.testing.expect(!(try repo.isProjectActive(5)));
}
