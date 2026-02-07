const std = @import("std");
const hierarchy_repo = @import("hierarchy_repository");
const HierarchyRepository = hierarchy_repo.HierarchyRepository;
const HierarchyRepositoryError = hierarchy_repo.HierarchyRepositoryError;
const HierarchyMatch = hierarchy_repo.HierarchyMatch;
const domain_hierarchy = @import("domain_hierarchy");
const ImportStats = domain_hierarchy.ImportStats;
const migrations = @import("migrations");
const c = migrations.c;

/// DuckDB implementation of HierarchyRepository.
pub const DuckDbHierarchyRepository = struct {
    conn: c.duckdb_connection,
    allocator: std.mem.Allocator,

    pub fn init(conn: c.duckdb_connection, allocator: std.mem.Allocator) DuckDbHierarchyRepository {
        return .{
            .conn = conn,
            .allocator = allocator,
        };
    }

    pub fn importFromFile(self: *DuckDbHierarchyRepository, file_path: []const u8) HierarchyRepositoryError!ImportStats {
        // Read file content
        const file = std.fs.cwd().openFile(file_path, .{}) catch {
            return HierarchyRepositoryError.FileReadError;
        };
        defer file.close();

        const stat = file.stat() catch {
            return HierarchyRepositoryError.FileReadError;
        };
        const content = self.allocator.alloc(u8, stat.size) catch {
            return HierarchyRepositoryError.OutOfMemory;
        };
        defer self.allocator.free(content);

        _ = file.preadAll(content, 0) catch {
            return HierarchyRepositoryError.FileReadError;
        };

        return self.importFromJson(content);
    }

    pub fn importFromJson(self: *DuckDbHierarchyRepository, json_content: []const u8) HierarchyRepositoryError!ImportStats {
        var stats = ImportStats{};

        // Clear mutable leaf data first. Project/customer rows are upserted below.
        // DuckDB table rewrites in migration 13 can leave delete dependencies on projects.
        self.execQuery("DELETE FROM kinds") catch return HierarchyRepositoryError.InsertFailed;
        self.execQuery("DELETE FROM activities") catch return HierarchyRepositoryError.InsertFailed;

        // Parse JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_content, .{}) catch {
            return HierarchyRepositoryError.ParseError;
        };
        defer parsed.deinit();

        const customers = parsed.value.array.items;

        for (customers) |customer_val| {
            const customer_obj = customer_val.object;

            const customer_id = customer_obj.get("CustomerId").?.integer;
            const customer_name = customer_obj.get("Name").?.string;

            self.insertCustomer(customer_id, customer_name) catch return HierarchyRepositoryError.InsertFailed;
            stats.customers += 1;

            const projects = customer_obj.get("Projects").?.array.items;
            for (projects) |project_val| {
                const project_obj = project_val.object;

                const project_id = project_obj.get("ProjectId").?.integer;
                const project_name = project_obj.get("id").?.string;

                self.insertProject(project_id, customer_id, project_name) catch return HierarchyRepositoryError.InsertFailed;
                stats.projects += 1;

                const phases = project_obj.get("TimePhases").?.array.items;
                for (phases) |phase_val| {
                    const phase_obj = phase_val.object;

                    const activities = phase_obj.get("Activities").?.array.items;
                    for (activities) |activity_val| {
                        const activity_obj = activity_val.object;

                        const activity_id = activity_obj.get("ActivityId").?.integer;
                        const activity_name = activity_obj.get("Name").?.string;

                        self.insertActivity(activity_id, project_id, activity_name) catch return HierarchyRepositoryError.InsertFailed;
                        stats.activities += 1;

                        const kinds = activity_obj.get("Kinds").?.array.items;
                        for (kinds) |kind_val| {
                            const kind_obj = kind_val.object;

                            const kind_id = kind_obj.get("KindId").?.integer;
                            const kind_name = kind_obj.get("Name").?.string;

                            const billable = !std.mem.containsAtLeast(u8, activity_name, 1, "Not billable") and
                                !std.mem.containsAtLeast(u8, activity_name, 1, "non billable") and
                                !std.mem.containsAtLeast(u8, activity_name, 1, "non-billable");

                            self.insertKind(kind_id, activity_id, kind_name, billable) catch return HierarchyRepositoryError.InsertFailed;
                            stats.kinds += 1;
                        }
                    }
                }
            }
        }

        return stats;
    }

    pub fn searchFullHierarchy(self: *DuckDbHierarchyRepository, search_term: []const u8) HierarchyRepositoryError![]HierarchyMatch {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql =
            \\SELECT k.activity_id, k.kind_id,
            \\       cu.name || ' > ' || p.name || ' > ' || a.name || ' > ' || k.name as full_path
            \\FROM kinds k
            \\JOIN activities a ON k.activity_id = a.activity_id
            \\JOIN projects p ON a.project_id = p.project_id
            \\JOIN customers cu ON p.customer_id = cu.customer_id
            \\WHERE LOWER(k.name) LIKE '%' || LOWER(?) || '%'
            \\   OR LOWER(a.name) LIKE '%' || LOWER(?) || '%'
            \\   OR LOWER(p.name) LIKE '%' || LOWER(?) || '%'
            \\   OR LOWER(cu.name) LIKE '%' || LOWER(?) || '%'
            \\ORDER BY cu.name, p.name, a.name, k.name
            \\LIMIT 50
        ;

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return HierarchyRepositoryError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_varchar_length(stmt, 1, search_term.ptr, search_term.len);
        _ = c.duckdb_bind_varchar_length(stmt, 2, search_term.ptr, search_term.len);
        _ = c.duckdb_bind_varchar_length(stmt, 3, search_term.ptr, search_term.len);
        _ = c.duckdb_bind_varchar_length(stmt, 4, search_term.ptr, search_term.len);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return HierarchyRepositoryError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        if (row_count == 0) {
            return &[_]HierarchyMatch{};
        }

        var matches = self.allocator.alloc(HierarchyMatch, row_count) catch {
            return HierarchyRepositoryError.OutOfMemory;
        };
        errdefer self.allocator.free(matches);

        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);
            matches[i].activity_id = c.duckdb_value_int64(&result, 0, row);
            matches[i].kind_id = c.duckdb_value_int64(&result, 1, row);

            const path_ptr = c.duckdb_value_varchar(&result, 2, row);
            if (path_ptr != null) {
                const path_len = std.mem.len(path_ptr);
                const path_copy = self.allocator.alloc(u8, path_len) catch {
                    // Clean up previously allocated paths
                    for (0..i) |j| {
                        self.allocator.free(@constCast(matches[j].display_path));
                    }
                    self.allocator.free(matches);
                    return HierarchyRepositoryError.OutOfMemory;
                };
                @memcpy(path_copy, path_ptr[0..path_len]);
                matches[i].display_path = path_copy;
                c.duckdb_free(path_ptr);
            } else {
                matches[i].display_path = "";
            }
        }

        return matches;
    }

    pub fn getKindPath(self: *DuckDbHierarchyRepository, kind_id: i64) HierarchyRepositoryError![]const u8 {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql =
            \\SELECT cu.name || ' > ' || p.name || ' > ' || a.name || ' > ' || k.name
            \\FROM kinds k
            \\JOIN activities a ON k.activity_id = a.activity_id
            \\JOIN projects p ON a.project_id = p.project_id
            \\JOIN customers cu ON p.customer_id = cu.customer_id
            \\WHERE k.kind_id = ?
        ;

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return HierarchyRepositoryError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, kind_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return HierarchyRepositoryError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        if (c.duckdb_row_count(&result) == 0) {
            return HierarchyRepositoryError.QueryFailed;
        }

        const path_ptr = c.duckdb_value_varchar(&result, 0, 0);
        if (path_ptr == null) {
            return HierarchyRepositoryError.QueryFailed;
        }

        const path_len = std.mem.len(path_ptr);
        const path_copy = self.allocator.alloc(u8, path_len) catch {
            c.duckdb_free(path_ptr);
            return HierarchyRepositoryError.OutOfMemory;
        };
        @memcpy(path_copy, path_ptr[0..path_len]);
        c.duckdb_free(path_ptr);

        return path_copy;
    }

    /// Get project name and activity name for a kind_id.
    /// Returns two strings: project_name and activity_name (caller must free both).
    pub fn getProjectAndActivityForKind(self: *DuckDbHierarchyRepository, kind_id: i64) HierarchyRepositoryError!struct { project: []const u8, activity: []const u8 } {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql =
            \\SELECT cu.name || ' > ' || p.name, a.name
            \\FROM kinds k
            \\JOIN activities a ON k.activity_id = a.activity_id
            \\JOIN projects p ON a.project_id = p.project_id
            \\JOIN customers cu ON p.customer_id = cu.customer_id
            \\WHERE k.kind_id = ?
        ;

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return HierarchyRepositoryError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, kind_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return HierarchyRepositoryError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        if (c.duckdb_row_count(&result) == 0) {
            return HierarchyRepositoryError.QueryFailed;
        }

        // Get project name (column 0)
        const project_ptr = c.duckdb_value_varchar(&result, 0, 0);
        if (project_ptr == null) {
            return HierarchyRepositoryError.QueryFailed;
        }
        const project_len = std.mem.len(project_ptr);
        const project_copy = self.allocator.alloc(u8, project_len) catch {
            c.duckdb_free(project_ptr);
            return HierarchyRepositoryError.OutOfMemory;
        };
        @memcpy(project_copy, project_ptr[0..project_len]);
        c.duckdb_free(project_ptr);

        // Get activity name (column 1)
        const activity_ptr = c.duckdb_value_varchar(&result, 1, 0);
        if (activity_ptr == null) {
            self.allocator.free(project_copy);
            return HierarchyRepositoryError.QueryFailed;
        }
        const activity_len = std.mem.len(activity_ptr);
        const activity_copy = self.allocator.alloc(u8, activity_len) catch {
            self.allocator.free(project_copy);
            c.duckdb_free(activity_ptr);
            return HierarchyRepositoryError.OutOfMemory;
        };
        @memcpy(activity_copy, activity_ptr[0..activity_len]);
        c.duckdb_free(activity_ptr);

        return .{ .project = project_copy, .activity = activity_copy };
    }

    pub fn freeMatches(self: *DuckDbHierarchyRepository, matches: []HierarchyMatch) void {
        for (matches) |m| {
            if (m.display_path.len > 0) {
                self.allocator.free(@constCast(m.display_path));
            }
        }
        self.allocator.free(matches);
    }

    pub fn freePath(self: *DuckDbHierarchyRepository, path: []const u8) void {
        self.allocator.free(@constCast(path));
    }

    /// Convert to the interface type.
    pub fn repository(self: *DuckDbHierarchyRepository) HierarchyRepository {
        return HierarchyRepository{
            .ptr = self,
            .vtable = &.{
                .importFromFile = importFromFileVtable,
                .importFromJson = importFromJsonVtable,
                .searchFullHierarchy = searchFullHierarchyVtable,
                .getKindPath = getKindPathVtable,
                .freeMatches = freeMatchesVtable,
                .freePath = freePathVtable,
            },
        };
    }

    fn importFromFileVtable(ptr: *anyopaque, file_path: []const u8) HierarchyRepositoryError!ImportStats {
        const self: *DuckDbHierarchyRepository = @ptrCast(@alignCast(ptr));
        return self.importFromFile(file_path);
    }

    fn importFromJsonVtable(ptr: *anyopaque, json_content: []const u8) HierarchyRepositoryError!ImportStats {
        const self: *DuckDbHierarchyRepository = @ptrCast(@alignCast(ptr));
        return self.importFromJson(json_content);
    }

    fn searchFullHierarchyVtable(ptr: *anyopaque, search_term: []const u8) HierarchyRepositoryError![]HierarchyMatch {
        const self: *DuckDbHierarchyRepository = @ptrCast(@alignCast(ptr));
        return self.searchFullHierarchy(search_term);
    }

    fn getKindPathVtable(ptr: *anyopaque, kind_id: i64) HierarchyRepositoryError![]const u8 {
        const self: *DuckDbHierarchyRepository = @ptrCast(@alignCast(ptr));
        return self.getKindPath(kind_id);
    }

    fn freeMatchesVtable(ptr: *anyopaque, matches: []HierarchyMatch) void {
        const self: *DuckDbHierarchyRepository = @ptrCast(@alignCast(ptr));
        self.freeMatches(matches);
    }

    fn freePathVtable(ptr: *anyopaque, path: []const u8) void {
        const self: *DuckDbHierarchyRepository = @ptrCast(@alignCast(ptr));
        self.freePath(path);
    }

    // Helper methods

    fn insertCustomer(self: *DuckDbHierarchyRepository, customer_id: i64, name: []const u8) !void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "INSERT INTO customers (customer_id, name) VALUES (?, ?) ON CONFLICT (customer_id) DO UPDATE SET name = excluded.name";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return error.InsertFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, customer_id);
        _ = c.duckdb_bind_varchar_length(stmt, 2, name.ptr, name.len);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return error.InsertFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    fn insertProject(self: *DuckDbHierarchyRepository, project_id: i64, customer_id: i64, name: []const u8) !void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "INSERT INTO projects (project_id, customer_id, name) VALUES (?, ?, ?) ON CONFLICT (project_id) DO UPDATE SET customer_id = excluded.customer_id, name = excluded.name";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return error.InsertFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, project_id);
        _ = c.duckdb_bind_int64(stmt, 2, customer_id);
        _ = c.duckdb_bind_varchar_length(stmt, 3, name.ptr, name.len);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return error.InsertFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    fn insertActivity(self: *DuckDbHierarchyRepository, activity_id: i64, project_id: i64, name: []const u8) !void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "INSERT INTO activities (activity_id, project_id, name, title) VALUES (?, ?, ?, ?) ON CONFLICT (activity_id) DO UPDATE SET project_id = excluded.project_id, name = excluded.name, title = excluded.title";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return error.InsertFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, activity_id);
        _ = c.duckdb_bind_int64(stmt, 2, project_id);
        _ = c.duckdb_bind_varchar_length(stmt, 3, name.ptr, name.len);
        _ = c.duckdb_bind_varchar_length(stmt, 4, name.ptr, name.len);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return error.InsertFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    fn insertKind(self: *DuckDbHierarchyRepository, kind_id: i64, activity_id: i64, name: []const u8, billable: bool) !void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "INSERT INTO kinds (kind_id, activity_id, name, billable) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return error.InsertFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, kind_id);
        _ = c.duckdb_bind_int64(stmt, 2, activity_id);
        _ = c.duckdb_bind_varchar_length(stmt, 3, name.ptr, name.len);
        _ = c.duckdb_bind_boolean(stmt, 4, billable);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return error.InsertFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    fn execQuery(self: *DuckDbHierarchyRepository, sql: [*c]const u8) !void {
        var result: c.duckdb_result = undefined;
        if (c.duckdb_query(self.conn, sql, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return error.QueryFailed;
        }
        c.duckdb_destroy_result(&result);
    }
};
