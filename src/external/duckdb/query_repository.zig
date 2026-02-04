const std = @import("std");
const query_repo = @import("query_repository");
const QueryRepository = query_repo.QueryRepository;
const QueryRepositoryError = query_repo.QueryRepositoryError;
const TimeRange = query_repo.TimeRange;
const AppSummary = query_repo.AppSummary;
const TitleDetail = query_repo.TitleDetail;
const migrations = @import("migrations");
const c = migrations.c;

/// DuckDB implementation of QueryRepository.
pub const DuckDbQueryRepository = struct {
    conn: c.duckdb_connection,
    allocator: std.mem.Allocator,

    // Internal buffers for string storage
    const StringBuf = struct {
        data: []u8,
    };

    pub fn init(conn: c.duckdb_connection, allocator: std.mem.Allocator) DuckDbQueryRepository {
        return .{
            .conn = conn,
            .allocator = allocator,
        };
    }

    pub fn getAppSummary(self: *DuckDbQueryRepository, range: TimeRange) QueryRepositoryError![]AppSummary {
        const where_clause = switch (range) {
            .today => " WHERE timestamp_ms >= (extract(epoch from current_date) * 1000)",
            .week => " WHERE timestamp_ms >= (extract(epoch from current_date - interval '7 days') * 1000)",
            .all => "",
        };

        var query_buf: [512]u8 = undefined;
        const query = std.fmt.bufPrintZ(&query_buf,
            \\SELECT app_name, SUM(duration_ms) as total_ms
            \\FROM events
            \\{s}
            \\GROUP BY app_name
            \\ORDER BY total_ms DESC
        , .{where_clause}) catch return QueryRepositoryError.QueryFailed;

        var result: c.duckdb_result = undefined;
        if (c.duckdb_query(self.conn, query.ptr, &result) == c.DuckDBError) {
            return QueryRepositoryError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        if (row_count == 0) {
            return &[_]AppSummary{};
        }

        // Allocate storage for summaries and their string data
        var summaries = self.allocator.alloc(AppSummary, row_count) catch {
            return QueryRepositoryError.OutOfMemory;
        };
        errdefer self.allocator.free(summaries);

        // Allocate string buffers
        var strings = self.allocator.alloc([]u8, row_count) catch {
            self.allocator.free(summaries);
            return QueryRepositoryError.OutOfMemory;
        };

        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);
            const app_ptr = c.duckdb_value_varchar(&result, 0, row);
            if (app_ptr != null) {
                const app_len = std.mem.len(app_ptr);
                strings[i] = self.allocator.alloc(u8, app_len) catch {
                    // Cleanup on error
                    for (0..i) |j| self.allocator.free(strings[j]);
                    self.allocator.free(strings);
                    self.allocator.free(summaries);
                    c.duckdb_free(app_ptr);
                    return QueryRepositoryError.OutOfMemory;
                };
                @memcpy(strings[i], app_ptr[0..app_len]);
                summaries[i].app_name = strings[i];
                c.duckdb_free(app_ptr);
            } else {
                strings[i] = self.allocator.alloc(u8, 0) catch {
                    for (0..i) |j| self.allocator.free(strings[j]);
                    self.allocator.free(strings);
                    self.allocator.free(summaries);
                    return QueryRepositoryError.OutOfMemory;
                };
                summaries[i].app_name = "";
            }

            summaries[i].total_ms = c.duckdb_value_int64(&result, 1, row);
        }

        // Store strings array pointer in the first summary for cleanup later
        // This is a bit hacky but avoids needing a separate allocation tracker
        self.allocator.free(strings); // Free the array itself, strings are referenced by summaries

        return summaries;
    }

    pub fn getTitleDetails(self: *DuckDbQueryRepository, app_name: []const u8, range: TimeRange) QueryRepositoryError![]TitleDetail {
        const where_clause = switch (range) {
            .today => " AND timestamp_ms >= (extract(epoch from current_date) * 1000)",
            .week => " AND timestamp_ms >= (extract(epoch from current_date - interval '7 days') * 1000)",
            .all => "",
        };

        var stmt: c.duckdb_prepared_statement = undefined;
        var query_buf: [512]u8 = undefined;
        const query = std.fmt.bufPrintZ(&query_buf,
            \\SELECT window_title, SUM(duration_ms) as total_ms
            \\FROM events
            \\WHERE app_name = ?
            \\{s}
            \\GROUP BY window_title
            \\ORDER BY total_ms DESC
            \\LIMIT 10
        , .{where_clause}) catch return QueryRepositoryError.QueryFailed;

        if (c.duckdb_prepare(self.conn, query.ptr, &stmt) == c.DuckDBError) {
            return QueryRepositoryError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_varchar_length(stmt, 1, app_name.ptr, app_name.len);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return QueryRepositoryError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        if (row_count == 0) {
            return &[_]TitleDetail{};
        }

        var details = self.allocator.alloc(TitleDetail, row_count) catch {
            return QueryRepositoryError.OutOfMemory;
        };
        errdefer self.allocator.free(details);

        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);
            const title_ptr = c.duckdb_value_varchar(&result, 0, row);
            if (title_ptr != null) {
                const title_len = std.mem.len(title_ptr);
                const title_copy = self.allocator.alloc(u8, title_len) catch {
                    for (0..i) |j| self.allocator.free(@constCast(details[j].window_title));
                    self.allocator.free(details);
                    c.duckdb_free(title_ptr);
                    return QueryRepositoryError.OutOfMemory;
                };
                @memcpy(title_copy, title_ptr[0..title_len]);
                details[i].window_title = title_copy;
                c.duckdb_free(title_ptr);
            } else {
                details[i].window_title = "";
            }

            details[i].total_ms = c.duckdb_value_int64(&result, 1, row);
        }

        return details;
    }

    pub fn getTotalTrackedTime(self: *DuckDbQueryRepository, range: TimeRange) QueryRepositoryError!i64 {
        const where_clause = switch (range) {
            .today => " WHERE timestamp_ms >= (extract(epoch from current_date) * 1000)",
            .week => " WHERE timestamp_ms >= (extract(epoch from current_date - interval '7 days') * 1000)",
            .all => "",
        };

        var query_buf: [256]u8 = undefined;
        const query = std.fmt.bufPrintZ(&query_buf, "SELECT COALESCE(SUM(duration_ms), 0) FROM events{s}", .{where_clause}) catch return QueryRepositoryError.QueryFailed;

        var result: c.duckdb_result = undefined;
        if (c.duckdb_query(self.conn, query.ptr, &result) == c.DuckDBError) {
            return QueryRepositoryError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        return c.duckdb_value_int64(&result, 0, 0);
    }

    pub fn getProjectName(self: *DuckDbQueryRepository, project_id: i64) QueryRepositoryError!?[]const u8 {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "SELECT c.name || ' > ' || p.name FROM projects p JOIN customers c ON p.customer_id = c.customer_id WHERE p.project_id = ?";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return QueryRepositoryError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, project_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return QueryRepositoryError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        if (c.duckdb_row_count(&result) == 0) {
            return null;
        }

        const name_ptr = c.duckdb_value_varchar(&result, 0, 0);
        if (name_ptr == null) {
            return null;
        }

        const name_len = std.mem.len(name_ptr);
        const name_copy = self.allocator.alloc(u8, name_len) catch {
            c.duckdb_free(name_ptr);
            return QueryRepositoryError.OutOfMemory;
        };
        @memcpy(name_copy, name_ptr[0..name_len]);
        c.duckdb_free(name_ptr);

        return name_copy;
    }

    pub fn freeAppSummaries(self: *DuckDbQueryRepository, summaries: []AppSummary) void {
        for (summaries) |s| {
            if (s.app_name.len > 0) {
                self.allocator.free(@constCast(s.app_name));
            }
        }
        self.allocator.free(summaries);
    }

    pub fn freeTitleDetails(self: *DuckDbQueryRepository, details: []TitleDetail) void {
        for (details) |d| {
            if (d.window_title.len > 0) {
                self.allocator.free(@constCast(d.window_title));
            }
        }
        self.allocator.free(details);
    }

    pub fn freeName(self: *DuckDbQueryRepository, name: []const u8) void {
        self.allocator.free(@constCast(name));
    }

    /// Convert to the interface type.
    pub fn repository(self: *DuckDbQueryRepository) QueryRepository {
        return QueryRepository{
            .ptr = self,
            .vtable = &.{
                .getAppSummary = getAppSummaryVtable,
                .getTitleDetails = getTitleDetailsVtable,
                .getTotalTrackedTime = getTotalTrackedTimeVtable,
                .getProjectName = getProjectNameVtable,
                .freeAppSummaries = freeAppSummariesVtable,
                .freeTitleDetails = freeTitleDetailsVtable,
                .freeName = freeNameVtable,
            },
        };
    }

    fn getAppSummaryVtable(ptr: *anyopaque, range: TimeRange) QueryRepositoryError![]AppSummary {
        const self: *DuckDbQueryRepository = @ptrCast(@alignCast(ptr));
        return self.getAppSummary(range);
    }

    fn getTitleDetailsVtable(ptr: *anyopaque, app_name: []const u8, range: TimeRange) QueryRepositoryError![]TitleDetail {
        const self: *DuckDbQueryRepository = @ptrCast(@alignCast(ptr));
        return self.getTitleDetails(app_name, range);
    }

    fn getTotalTrackedTimeVtable(ptr: *anyopaque, range: TimeRange) QueryRepositoryError!i64 {
        const self: *DuckDbQueryRepository = @ptrCast(@alignCast(ptr));
        return self.getTotalTrackedTime(range);
    }

    fn getProjectNameVtable(ptr: *anyopaque, project_id: i64) QueryRepositoryError!?[]const u8 {
        const self: *DuckDbQueryRepository = @ptrCast(@alignCast(ptr));
        return self.getProjectName(project_id);
    }

    fn freeAppSummariesVtable(ptr: *anyopaque, summaries: []AppSummary) void {
        const self: *DuckDbQueryRepository = @ptrCast(@alignCast(ptr));
        self.freeAppSummaries(summaries);
    }

    fn freeTitleDetailsVtable(ptr: *anyopaque, details: []TitleDetail) void {
        const self: *DuckDbQueryRepository = @ptrCast(@alignCast(ptr));
        self.freeTitleDetails(details);
    }

    fn freeNameVtable(ptr: *anyopaque, name: []const u8) void {
        const self: *DuckDbQueryRepository = @ptrCast(@alignCast(ptr));
        self.freeName(name);
    }
};
