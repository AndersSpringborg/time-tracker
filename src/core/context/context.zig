const std = @import("std");
const migrations = @import("migrations");
pub const c = migrations.c;

pub const ContextError = error{
    QueryFailed,
    AllocFailed,
};

pub const ProjectAssignment = struct {
    id: i64,
    project_id: i64,
    started_at: ?i64, // Timestamp in ms
    ended_at: ?i64, // Timestamp in ms, null if active
};

/// Manages active project assignments for narrowing search results.
pub const ProjectContext = struct {
    conn: c.duckdb_connection,
    allocator: std.mem.Allocator,

    pub fn init(conn: c.duckdb_connection, allocator: std.mem.Allocator) ProjectContext {
        return .{
            .conn = conn,
            .allocator = allocator,
        };
    }

    /// Add a project to the active context. Idempotent - won't add if already active.
    pub fn addProject(self: *ProjectContext, project_id: i64) ContextError!void {
        // Check if already active
        if (try self.isProjectActive(project_id)) {
            return; // Already active, nothing to do
        }

        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "INSERT INTO project_assignments (project_id) VALUES (?)";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return ContextError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, project_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ContextError.QueryFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    /// End a project assignment (set ended_at to now).
    pub fn endProject(self: *ProjectContext, project_id: i64) ContextError!void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "UPDATE project_assignments SET ended_at = current_timestamp WHERE project_id = ? AND ended_at IS NULL";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return ContextError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, project_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ContextError.QueryFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    /// End all active project assignments.
    pub fn endAllProjects(self: *ProjectContext) ContextError!void {
        var result: c.duckdb_result = undefined;
        const sql = "UPDATE project_assignments SET ended_at = current_timestamp WHERE ended_at IS NULL";

        if (c.duckdb_query(self.conn, sql, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ContextError.QueryFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    /// Get all active project assignments (ended_at IS NULL).
    pub fn getActiveProjects(self: *ProjectContext) ContextError![]ProjectAssignment {
        var result: c.duckdb_result = undefined;
        const sql = "SELECT id, project_id, started_at, ended_at FROM project_assignments WHERE ended_at IS NULL ORDER BY started_at DESC";

        if (c.duckdb_query(self.conn, sql, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ContextError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var assignments = self.allocator.alloc(ProjectAssignment, row_count) catch {
            return ContextError.AllocFailed;
        };

        for (0..row_count) |i| {
            const idx: c.idx_t = @intCast(i);
            assignments[i] = .{
                .id = c.duckdb_value_int64(&result, 0, idx),
                .project_id = c.duckdb_value_int64(&result, 1, idx),
                .started_at = if (c.duckdb_value_is_null(&result, 2, idx)) null else c.duckdb_value_int64(&result, 2, idx),
                .ended_at = if (c.duckdb_value_is_null(&result, 3, idx)) null else c.duckdb_value_int64(&result, 3, idx),
            };
        }

        return assignments;
    }

    /// Get just the IDs of active projects.
    pub fn getActiveProjectIds(self: *ProjectContext) ContextError![]i64 {
        var result: c.duckdb_result = undefined;
        const sql = "SELECT project_id FROM project_assignments WHERE ended_at IS NULL ORDER BY started_at DESC";

        if (c.duckdb_query(self.conn, sql, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ContextError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var ids = self.allocator.alloc(i64, row_count) catch {
            return ContextError.AllocFailed;
        };

        for (0..row_count) |i| {
            const idx: c.idx_t = @intCast(i);
            ids[i] = c.duckdb_value_int64(&result, 0, idx);
        }

        return ids;
    }

    /// Check if any projects are currently active.
    pub fn hasActiveProjects(self: *ProjectContext) ContextError!bool {
        var result: c.duckdb_result = undefined;
        const sql = "SELECT COUNT(*) FROM project_assignments WHERE ended_at IS NULL";

        if (c.duckdb_query(self.conn, sql, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ContextError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const count = c.duckdb_value_int64(&result, 0, 0);
        return count > 0;
    }

    /// Check if a specific project is currently active.
    pub fn isProjectActive(self: *ProjectContext, project_id: i64) ContextError!bool {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "SELECT COUNT(*) FROM project_assignments WHERE project_id = ? AND ended_at IS NULL";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return ContextError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, project_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ContextError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const count = c.duckdb_value_int64(&result, 0, 0);
        return count > 0;
    }
};
