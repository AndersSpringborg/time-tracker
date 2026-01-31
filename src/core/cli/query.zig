const std = @import("std");
const c = @cImport({
    @cInclude("duckdb.h");
});

pub const QueryError = error{
    OpenFailed,
    ConnectFailed,
    QueryFailed,
};

pub const TimeRange = enum {
    today,
    week,
    all,
};

pub const AppSummary = struct {
    app_name: []const u8,
    total_ms: i64,
    app_name_buf: [256]u8 = undefined,

    pub fn formatDuration(self: AppSummary, buf: []u8) []const u8 {
        const total_secs = @divFloor(self.total_ms, 1000);
        const hours = @divFloor(total_secs, 3600);
        const mins = @mod(@divFloor(total_secs, 60), 60);
        const secs = @mod(total_secs, 60);

        if (hours > 0) {
            return std.fmt.bufPrint(buf, "{d}h {d}m {d}s", .{ hours, mins, secs }) catch "?";
        } else if (mins > 0) {
            return std.fmt.bufPrint(buf, "{d}m {d}s", .{ mins, secs }) catch "?";
        } else {
            return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch "?";
        }
    }
};

pub const TitleDetail = struct {
    window_title: []const u8,
    total_ms: i64,
    window_title_buf: [512]u8 = undefined,
};

pub const QueryRunner = struct {
    db: c.duckdb_database,
    conn: c.duckdb_connection,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db_path: [*c]const u8) QueryError!QueryRunner {
        var db: c.duckdb_database = undefined;
        var conn: c.duckdb_connection = undefined;

        if (c.duckdb_open(db_path, &db) == c.DuckDBError) {
            return QueryError.OpenFailed;
        }

        if (c.duckdb_connect(db, &conn) == c.DuckDBError) {
            c.duckdb_close(&db);
            return QueryError.ConnectFailed;
        }

        return QueryRunner{
            .db = db,
            .conn = conn,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QueryRunner) void {
        c.duckdb_disconnect(&self.conn);
        c.duckdb_close(&self.db);
    }

    pub fn getAppSummary(self: *QueryRunner, range: TimeRange) ![]AppSummary {
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
        , .{where_clause}) catch return QueryError.QueryFailed;

        var result: c.duckdb_result = undefined;
        if (c.duckdb_query(self.conn, query.ptr, &result) == c.DuckDBError) {
            return QueryError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        if (row_count == 0) {
            return &[_]AppSummary{};
        }

        var summaries = try self.allocator.alloc(AppSummary, row_count);
        errdefer self.allocator.free(summaries);

        for (0..row_count) |i| {
            const app_ptr = c.duckdb_value_varchar(&result, 0, i);
            if (app_ptr != null) {
                const app_len = std.mem.len(app_ptr);
                @memcpy(summaries[i].app_name_buf[0..app_len], app_ptr[0..app_len]);
                summaries[i].app_name = summaries[i].app_name_buf[0..app_len];
                c.duckdb_free(app_ptr);
            } else {
                summaries[i].app_name = "";
            }

            summaries[i].total_ms = c.duckdb_value_int64(&result, 1, i);
        }

        return summaries;
    }

    pub fn getTitleDetails(self: *QueryRunner, app_name: []const u8, range: TimeRange) ![]TitleDetail {
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
        , .{where_clause}) catch return QueryError.QueryFailed;

        if (c.duckdb_prepare(self.conn, query.ptr, &stmt) == c.DuckDBError) {
            return QueryError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_varchar_length(stmt, 1, app_name.ptr, app_name.len);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return QueryError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        if (row_count == 0) {
            return &[_]TitleDetail{};
        }

        var details = try self.allocator.alloc(TitleDetail, row_count);
        errdefer self.allocator.free(details);

        for (0..row_count) |i| {
            const title_ptr = c.duckdb_value_varchar(&result, 0, i);
            if (title_ptr != null) {
                const title_len = @min(std.mem.len(title_ptr), details[i].window_title_buf.len);
                @memcpy(details[i].window_title_buf[0..title_len], title_ptr[0..title_len]);
                details[i].window_title = details[i].window_title_buf[0..title_len];
                c.duckdb_free(title_ptr);
            } else {
                details[i].window_title = "";
            }

            details[i].total_ms = c.duckdb_value_int64(&result, 1, i);
        }

        return details;
    }

    pub fn getTotalTrackedTime(self: *QueryRunner, range: TimeRange) !i64 {
        const where_clause = switch (range) {
            .today => " WHERE timestamp_ms >= (extract(epoch from current_date) * 1000)",
            .week => " WHERE timestamp_ms >= (extract(epoch from current_date - interval '7 days') * 1000)",
            .all => "",
        };

        var query_buf: [256]u8 = undefined;
        const query = std.fmt.bufPrintZ(&query_buf, "SELECT COALESCE(SUM(duration_ms), 0) FROM events{s}", .{where_clause}) catch return QueryError.QueryFailed;

        var result: c.duckdb_result = undefined;
        if (c.duckdb_query(self.conn, query.ptr, &result) == c.DuckDBError) {
            return QueryError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        return c.duckdb_value_int64(&result, 0, 0);
    }
};

pub fn formatDuration(total_ms: i64, buf: []u8) []const u8 {
    const total_secs = @divFloor(total_ms, 1000);
    const hours = @divFloor(total_secs, 3600);
    const mins = @mod(@divFloor(total_secs, 60), 60);
    const secs = @mod(total_secs, 60);

    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}h {d}m {d}s", .{ hours, mins, secs }) catch "?";
    } else if (mins > 0) {
        return std.fmt.bufPrint(buf, "{d}m {d}s", .{ mins, secs }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch "?";
    }
}
