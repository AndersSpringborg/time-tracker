const std = @import("std");
const DuckDbHierarchyRepository = @import("duckdb_hierarchy_repository").DuckDbHierarchyRepository;
const migrations = @import("migrations");
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

    // Run migrations
    var migrator = try migrations.Migrator.init(conn);
    try migrator.run();

    return conn;
}

test "DuckDbHierarchyRepository imports JSON hierarchy" {
    const conn = try openInMemoryDb();
    var repo = DuckDbHierarchyRepository.init(conn, std.testing.allocator);

    const json =
        \\[{
        \\  "CustomerId": 1,
        \\  "Name": "Acme Corp",
        \\  "Projects": [{
        \\    "ProjectId": 10,
        \\    "id": "Website Redesign",
        \\    "TimePhases": [{
        \\      "PhaseId": 100,
        \\      "Name": "Development",
        \\      "Activities": [{
        \\        "ActivityId": 1000,
        \\        "Name": "Coding",
        \\        "Kinds": [{
        \\          "KindId": 10000,
        \\          "Name": "Frontend"
        \\        }]
        \\      }]
        \\    }]
        \\  }]
        \\}]
    ;

    const stats = try repo.importFromJson(json);

    try std.testing.expectEqual(@as(u32, 1), stats.customers);
    try std.testing.expectEqual(@as(u32, 1), stats.projects);
    try std.testing.expectEqual(@as(u32, 1), stats.activities);
    try std.testing.expectEqual(@as(u32, 1), stats.kinds);
}

test "DuckDbHierarchyRepository searches hierarchy" {
    const conn = try openInMemoryDb();
    var repo = DuckDbHierarchyRepository.init(conn, std.testing.allocator);

    // Import test data
    const json =
        \\[{
        \\  "CustomerId": 1,
        \\  "Name": "Acme Corp",
        \\  "Projects": [{
        \\    "ProjectId": 10,
        \\    "id": "Website",
        \\    "TimePhases": [{
        \\      "PhaseId": 100,
        \\      "Name": "Dev",
        \\      "Activities": [{
        \\        "ActivityId": 1000,
        \\        "Name": "Coding",
        \\        "Kinds": [
        \\          {"KindId": 10000, "Name": "Frontend"},
        \\          {"KindId": 10001, "Name": "Backend"}
        \\        ]
        \\      }]
        \\    }]
        \\  }]
        \\}]
    ;
    _ = try repo.importFromJson(json);

    // Search for "front"
    const matches = try repo.searchFullHierarchy("front");
    defer repo.freeMatches(matches);

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, matches[0].display_path, 1, "Frontend"));
    try std.testing.expectEqual(@as(i64, 10000), matches[0].kind_id);
}

test "DuckDbHierarchyRepository gets kind path" {
    const conn = try openInMemoryDb();
    var repo = DuckDbHierarchyRepository.init(conn, std.testing.allocator);

    // Import test data
    const json =
        \\[{
        \\  "CustomerId": 1,
        \\  "Name": "Acme",
        \\  "Projects": [{
        \\    "ProjectId": 10,
        \\    "id": "Web",
        \\    "TimePhases": [{
        \\      "PhaseId": 100,
        \\      "Name": "Dev",
        \\      "Activities": [{
        \\        "ActivityId": 1000,
        \\        "Name": "Code",
        \\        "Kinds": [{"KindId": 10000, "Name": "UI"}]
        \\      }]
        \\    }]
        \\  }]
        \\}]
    ;
    _ = try repo.importFromJson(json);

    const path = try repo.getKindPath(10000);
    defer repo.freePath(path);

    try std.testing.expect(std.mem.containsAtLeast(u8, path, 1, "Acme"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path, 1, "Web"));
    try std.testing.expect(std.mem.containsAtLeast(u8, path, 1, "UI"));
}
