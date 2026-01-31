const std = @import("std");
const migrations = @import("migrations");
const c = migrations.c;

pub const ImportError = error{
    ParseError,
    FileReadError,
    InsertFailed,
    OutOfMemory,
};

pub const Kind = struct {
    kind_id: i64,
    name: []const u8,
    billable: bool,
};

pub const Activity = struct {
    activity_id: i64,
    name: []const u8,
    kinds: []Kind,
};

pub const Phase = struct {
    phase_id: i64,
    name: []const u8,
    activities: []Activity,
};

pub const Project = struct {
    project_id: i64,
    name: []const u8,
    phases: []Phase,
};

pub const Customer = struct {
    customer_id: i64,
    name: []const u8,
    projects: []Project,
};

pub const HierarchyImporter = struct {
    conn: c.duckdb_connection,
    allocator: std.mem.Allocator,

    pub fn init(conn: c.duckdb_connection, allocator: std.mem.Allocator) HierarchyImporter {
        return HierarchyImporter{
            .conn = conn,
            .allocator = allocator,
        };
    }

    pub fn importFromFile(self: *HierarchyImporter, file_path: []const u8) !ImportStats {
        // Read file content
        const file = std.fs.cwd().openFile(file_path, .{}) catch {
            return ImportError.FileReadError;
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch {
            return ImportError.FileReadError;
        };
        defer self.allocator.free(content);

        return self.importFromJson(content);
    }

    pub fn importFromJson(self: *HierarchyImporter, json_content: []const u8) !ImportStats {
        var stats = ImportStats{};

        // Clear existing data first (in reverse order due to foreign keys)
        try self.execQuery("DELETE FROM kinds");
        try self.execQuery("DELETE FROM activities");
        try self.execQuery("DELETE FROM phases");
        try self.execQuery("DELETE FROM projects");
        try self.execQuery("DELETE FROM customers");

        // Parse JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_content, .{}) catch {
            return ImportError.ParseError;
        };
        defer parsed.deinit();

        const customers = parsed.value.array.items;

        for (customers) |customer_val| {
            const customer_obj = customer_val.object;

            const customer_id = customer_obj.get("CustomerId").?.integer;
            const customer_name = customer_obj.get("Name").?.string;

            try self.insertCustomer(customer_id, customer_name);
            stats.customers += 1;

            const projects = customer_obj.get("Projects").?.array.items;
            for (projects) |project_val| {
                const project_obj = project_val.object;

                const project_id = project_obj.get("ProjectId").?.integer;
                const project_name = project_obj.get("id").?.string; // "id" is the name field

                try self.insertProject(project_id, customer_id, project_name);
                stats.projects += 1;

                const phases = project_obj.get("Phases").?.array.items;
                for (phases) |phase_val| {
                    const phase_obj = phase_val.object;

                    const phase_id = phase_obj.get("PhaseId").?.integer;
                    const phase_name = phase_obj.get("Name").?.string;

                    try self.insertPhase(phase_id, project_id, phase_name);
                    stats.phases += 1;

                    const activities = phase_obj.get("Activities").?.array.items;
                    for (activities) |activity_val| {
                        const activity_obj = activity_val.object;

                        const activity_id = activity_obj.get("ActivityId").?.integer;
                        const activity_name = activity_obj.get("Name").?.string;

                        try self.insertActivity(activity_id, phase_id, activity_name);
                        stats.activities += 1;

                        const kinds = activity_obj.get("Kinds").?.array.items;
                        for (kinds) |kind_val| {
                            const kind_obj = kind_val.object;

                            const kind_id = kind_obj.get("KindId").?.integer;
                            const kind_name = kind_obj.get("Name").?.string;

                            // Determine billability from activity name
                            const billable = !std.mem.containsAtLeast(u8, activity_name, 1, "Not billable") and
                                !std.mem.containsAtLeast(u8, activity_name, 1, "non billable") and
                                !std.mem.containsAtLeast(u8, activity_name, 1, "non-billable");

                            try self.insertKind(kind_id, activity_id, kind_name, billable);
                            stats.kinds += 1;
                        }
                    }
                }
            }
        }

        return stats;
    }

    fn insertCustomer(self: *HierarchyImporter, customer_id: i64, name: []const u8) !void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "INSERT INTO customers (customer_id, name) VALUES (?, ?) ON CONFLICT (customer_id) DO UPDATE SET name = excluded.name";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return ImportError.InsertFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, customer_id);
        _ = c.duckdb_bind_varchar_length(stmt, 2, name.ptr, name.len);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ImportError.InsertFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    fn insertProject(self: *HierarchyImporter, project_id: i64, customer_id: i64, name: []const u8) !void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "INSERT INTO projects (project_id, customer_id, name) VALUES (?, ?, ?) ON CONFLICT (project_id) DO UPDATE SET customer_id = excluded.customer_id, name = excluded.name";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return ImportError.InsertFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, project_id);
        _ = c.duckdb_bind_int64(stmt, 2, customer_id);
        _ = c.duckdb_bind_varchar_length(stmt, 3, name.ptr, name.len);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ImportError.InsertFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    fn insertPhase(self: *HierarchyImporter, phase_id: i64, project_id: i64, name: []const u8) !void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "INSERT INTO phases (phase_id, project_id, name) VALUES (?, ?, ?) ON CONFLICT (phase_id) DO UPDATE SET project_id = excluded.project_id, name = excluded.name";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return ImportError.InsertFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, phase_id);
        _ = c.duckdb_bind_int64(stmt, 2, project_id);
        _ = c.duckdb_bind_varchar_length(stmt, 3, name.ptr, name.len);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ImportError.InsertFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    fn insertActivity(self: *HierarchyImporter, activity_id: i64, phase_id: i64, name: []const u8) !void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "INSERT INTO activities (activity_id, phase_id, name) VALUES (?, ?, ?) ON CONFLICT (activity_id) DO UPDATE SET phase_id = excluded.phase_id, name = excluded.name";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return ImportError.InsertFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, activity_id);
        _ = c.duckdb_bind_int64(stmt, 2, phase_id);
        _ = c.duckdb_bind_varchar_length(stmt, 3, name.ptr, name.len);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ImportError.InsertFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    fn insertKind(self: *HierarchyImporter, kind_id: i64, activity_id: i64, name: []const u8, billable: bool) !void {
        var stmt: c.duckdb_prepared_statement = undefined;
        // Use a composite key approach - since kind_id might repeat across activities
        const sql = "INSERT INTO kinds (kind_id, activity_id, name, billable) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return ImportError.InsertFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, kind_id);
        _ = c.duckdb_bind_int64(stmt, 2, activity_id);
        _ = c.duckdb_bind_varchar_length(stmt, 3, name.ptr, name.len);
        _ = c.duckdb_bind_boolean(stmt, 4, billable);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ImportError.InsertFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    fn execQuery(self: *HierarchyImporter, sql: [*c]const u8) !void {
        var result: c.duckdb_result = undefined;
        if (c.duckdb_query(self.conn, sql, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ImportError.InsertFailed;
        }
        c.duckdb_destroy_result(&result);
    }
};

pub const ImportStats = struct {
    customers: u32 = 0,
    projects: u32 = 0,
    phases: u32 = 0,
    activities: u32 = 0,
    kinds: u32 = 0,
};
