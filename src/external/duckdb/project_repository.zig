const std = @import("std");
const project_repository = @import("project_repository");
const ProjectRepository = project_repository.ProjectRepository;
const ProjectRepositoryError = project_repository.ProjectRepositoryError;
const migrations = @import("migrations");
const c = migrations.c;

/// DuckDB implementation of ProjectRepository.
pub const DuckDbProjectRepository = struct {
    conn: c.duckdb_connection,
    allocator: std.mem.Allocator,

    pub fn init(conn: c.duckdb_connection, allocator: std.mem.Allocator) DuckDbProjectRepository {
        return .{
            .conn = conn,
            .allocator = allocator,
        };
    }

    pub fn addProject(self: *DuckDbProjectRepository, project_id: i64) ProjectRepositoryError!void {
        // Check if already active
        if (try self.isProjectActive(project_id)) {
            return; // Already active, nothing to do
        }

        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "INSERT INTO project_assignments (project_id) VALUES (?)";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return error.InsertFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, project_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return error.InsertFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    pub fn endProject(self: *DuckDbProjectRepository, project_id: i64) ProjectRepositoryError!void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "UPDATE project_assignments SET ended_at = current_timestamp WHERE project_id = ? AND ended_at IS NULL";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return error.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, project_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return error.QueryFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    pub fn endAllProjects(self: *DuckDbProjectRepository) ProjectRepositoryError!void {
        var result: c.duckdb_result = undefined;
        const sql = "UPDATE project_assignments SET ended_at = current_timestamp WHERE ended_at IS NULL";

        if (c.duckdb_query(self.conn, sql, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return error.QueryFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    pub fn getActiveProjectIds(self: *DuckDbProjectRepository) ProjectRepositoryError![]i64 {
        var result: c.duckdb_result = undefined;
        const sql = "SELECT project_id FROM project_assignments WHERE ended_at IS NULL ORDER BY started_at DESC";

        if (c.duckdb_query(self.conn, sql, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return error.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var ids = self.allocator.alloc(i64, row_count) catch {
            return error.OutOfMemory;
        };

        for (0..row_count) |i| {
            const idx: c.idx_t = @intCast(i);
            ids[i] = c.duckdb_value_int64(&result, 0, idx);
        }

        return ids;
    }

    pub fn hasActiveProjects(self: *DuckDbProjectRepository) ProjectRepositoryError!bool {
        var result: c.duckdb_result = undefined;
        const sql = "SELECT COUNT(*) FROM project_assignments WHERE ended_at IS NULL";

        if (c.duckdb_query(self.conn, sql, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return error.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const count = c.duckdb_value_int64(&result, 0, 0);
        return count > 0;
    }

    pub fn isProjectActive(self: *DuckDbProjectRepository, project_id: i64) ProjectRepositoryError!bool {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "SELECT COUNT(*) FROM project_assignments WHERE project_id = ? AND ended_at IS NULL";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return error.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, project_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return error.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const count = c.duckdb_value_int64(&result, 0, 0);
        return count > 0;
    }

    pub fn freeProjectIds(self: *DuckDbProjectRepository, ids: []i64) void {
        self.allocator.free(ids);
    }

    /// Convert to the interface type.
    pub fn repository(self: *DuckDbProjectRepository) ProjectRepository {
        return ProjectRepository{
            .ptr = self,
            .vtable = &.{
                .addProject = addProjectVtable,
                .endProject = endProjectVtable,
                .endAllProjects = endAllProjectsVtable,
                .getActiveProjectIds = getActiveProjectIdsVtable,
                .hasActiveProjects = hasActiveProjectsVtable,
                .isProjectActive = isProjectActiveVtable,
                .freeProjectIds = freeProjectIdsVtable,
            },
        };
    }

    fn addProjectVtable(ptr: *anyopaque, project_id: i64) ProjectRepositoryError!void {
        const self: *DuckDbProjectRepository = @ptrCast(@alignCast(ptr));
        return self.addProject(project_id);
    }

    fn endProjectVtable(ptr: *anyopaque, project_id: i64) ProjectRepositoryError!void {
        const self: *DuckDbProjectRepository = @ptrCast(@alignCast(ptr));
        return self.endProject(project_id);
    }

    fn endAllProjectsVtable(ptr: *anyopaque) ProjectRepositoryError!void {
        const self: *DuckDbProjectRepository = @ptrCast(@alignCast(ptr));
        return self.endAllProjects();
    }

    fn getActiveProjectIdsVtable(ptr: *anyopaque) ProjectRepositoryError![]i64 {
        const self: *DuckDbProjectRepository = @ptrCast(@alignCast(ptr));
        return self.getActiveProjectIds();
    }

    fn hasActiveProjectsVtable(ptr: *anyopaque) ProjectRepositoryError!bool {
        const self: *DuckDbProjectRepository = @ptrCast(@alignCast(ptr));
        return self.hasActiveProjects();
    }

    fn isProjectActiveVtable(ptr: *anyopaque, project_id: i64) ProjectRepositoryError!bool {
        const self: *DuckDbProjectRepository = @ptrCast(@alignCast(ptr));
        return self.isProjectActive(project_id);
    }

    fn freeProjectIdsVtable(ptr: *anyopaque, ids: []i64) void {
        const self: *DuckDbProjectRepository = @ptrCast(@alignCast(ptr));
        self.freeProjectIds(ids);
    }
};
