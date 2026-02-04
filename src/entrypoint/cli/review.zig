const std = @import("std");
const migrations = @import("migrations");
const c = migrations.c;

pub const ReviewError = error{
    QueryFailed,
    UpdateFailed,
    OutOfMemory,
};

/// Represents an unmapped event that needs manual review
pub const UnmappedEvent = struct {
    id: i64,
    timestamp_ms: i64,
    app_name: []const u8,
    window_title: []const u8,
    duration_ms: i64,

    // Buffers for storing string data
    app_name_buf: [256]u8 = undefined,
    window_title_buf: [512]u8 = undefined,
};

pub const CustomerResult = struct {
    customer_id: i64,
    name: []const u8,
    name_buf: [256]u8 = undefined,
};

pub const ProjectResult = struct {
    project_id: i64,
    name: []const u8,
    name_buf: [256]u8 = undefined,
};

pub const PhaseResult = struct {
    phase_id: i64,
    name: []const u8,
    name_buf: [256]u8 = undefined,
};

pub const ActivityResult = struct {
    activity_id: i64,
    name: []const u8,
    name_buf: [256]u8 = undefined,
};

pub const KindResult = struct {
    kind_id: i64,
    name: []const u8,
    billable: bool,
    name_buf: [256]u8 = undefined,
};

pub const HierarchyMatch = struct {
    activity_id: i64,
    kind_id: i64,
    display_path: []const u8,
};

/// Date string buffer type (YYYY-MM-DD format)
pub const DateString = struct {
    buf: [10]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const DateString) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Reviewer = struct {
    conn: c.duckdb_connection,
    allocator: std.mem.Allocator,

    pub fn init(conn: c.duckdb_connection, allocator: std.mem.Allocator) Reviewer {
        return Reviewer{
            .conn = conn,
            .allocator = allocator,
        };
    }

    /// Get distinct dates that have unmapped events, sorted descending (newest first)
    pub fn getDatesWithUnmappedEvents(self: *Reviewer) ![]DateString {
        var result: c.duckdb_result = undefined;
        const query =
            \\SELECT DISTINCT DATE(TO_TIMESTAMP(timestamp_ms / 1000)) as event_date
            \\FROM events 
            \\WHERE activity_id IS NULL AND manually_mapped = false
            \\ORDER BY event_date DESC
        ;

        if (c.duckdb_query(self.conn, query, &result) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var dates = self.allocator.alloc(DateString, row_count) catch {
            return ReviewError.OutOfMemory;
        };

        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);
            dates[i] = DateString{};

            const date_ptr = c.duckdb_value_varchar(&result, 0, row);
            if (date_ptr != null) {
                const date_len = @min(std.mem.len(date_ptr), 10);
                @memcpy(dates[i].buf[0..date_len], date_ptr[0..date_len]);
                dates[i].len = date_len;
                c.duckdb_free(date_ptr);
            }
        }

        return dates;
    }

    /// Get unmapped events for a specific date (YYYY-MM-DD format)
    pub fn getUnmappedEventsForDate(self: *Reviewer, date: []const u8) ![]UnmappedEvent {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query =
            \\SELECT id, timestamp_ms, app_name, window_title, duration_ms 
            \\FROM events 
            \\WHERE activity_id IS NULL AND manually_mapped = false
            \\  AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
            \\ORDER BY timestamp_ms DESC
        ;

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_varchar_length(stmt, 1, date.ptr, date.len);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var events = self.allocator.alloc(UnmappedEvent, row_count) catch {
            return ReviewError.OutOfMemory;
        };

        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);

            events[i] = UnmappedEvent{
                .id = c.duckdb_value_int64(&result, 0, row),
                .timestamp_ms = c.duckdb_value_int64(&result, 1, row),
                .app_name = undefined,
                .window_title = undefined,
                .duration_ms = c.duckdb_value_int64(&result, 4, row),
            };

            // Copy app_name
            const app_ptr = c.duckdb_value_varchar(&result, 2, row);
            if (app_ptr != null) {
                const app_len = @min(std.mem.len(app_ptr), 255);
                @memcpy(events[i].app_name_buf[0..app_len], app_ptr[0..app_len]);
                events[i].app_name = events[i].app_name_buf[0..app_len];
                c.duckdb_free(app_ptr);
            } else {
                events[i].app_name = "";
            }

            // Copy window_title
            const title_ptr = c.duckdb_value_varchar(&result, 3, row);
            if (title_ptr != null) {
                const title_len = @min(std.mem.len(title_ptr), 511);
                @memcpy(events[i].window_title_buf[0..title_len], title_ptr[0..title_len]);
                events[i].window_title = events[i].window_title_buf[0..title_len];
                c.duckdb_free(title_ptr);
            } else {
                events[i].window_title = "";
            }
        }

        return events;
    }

    /// Get all unmapped events (where activity_id IS NULL AND manually_mapped = false)
    pub fn getUnmappedEvents(self: *Reviewer) ![]UnmappedEvent {
        var result: c.duckdb_result = undefined;
        const query =
            \\SELECT id, timestamp_ms, app_name, window_title, duration_ms 
            \\FROM events 
            \\WHERE activity_id IS NULL AND manually_mapped = false
            \\ORDER BY timestamp_ms DESC
        ;

        if (c.duckdb_query(self.conn, query, &result) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var events = self.allocator.alloc(UnmappedEvent, row_count) catch {
            return ReviewError.OutOfMemory;
        };

        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);

            events[i] = UnmappedEvent{
                .id = c.duckdb_value_int64(&result, 0, row),
                .timestamp_ms = c.duckdb_value_int64(&result, 1, row),
                .app_name = undefined,
                .window_title = undefined,
                .duration_ms = c.duckdb_value_int64(&result, 4, row),
            };

            // Copy app_name
            const app_ptr = c.duckdb_value_varchar(&result, 2, row);
            if (app_ptr != null) {
                const app_len = @min(std.mem.len(app_ptr), 255);
                @memcpy(events[i].app_name_buf[0..app_len], app_ptr[0..app_len]);
                events[i].app_name = events[i].app_name_buf[0..app_len];
                c.duckdb_free(app_ptr);
            } else {
                events[i].app_name = "";
            }

            // Copy window_title
            const title_ptr = c.duckdb_value_varchar(&result, 3, row);
            if (title_ptr != null) {
                const title_len = @min(std.mem.len(title_ptr), 511);
                @memcpy(events[i].window_title_buf[0..title_len], title_ptr[0..title_len]);
                events[i].window_title = events[i].window_title_buf[0..title_len];
                c.duckdb_free(title_ptr);
            } else {
                events[i].window_title = "";
            }
        }

        return events;
    }

    /// Search customers by name (case-insensitive)
    pub fn searchCustomers(self: *Reviewer, search_term: []const u8) ![]CustomerResult {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query =
            \\SELECT customer_id, name FROM customers 
            \\WHERE LOWER(name) LIKE '%' || LOWER(?) || '%'
            \\ORDER BY name LIMIT 20
        ;

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_varchar_length(stmt, 1, search_term.ptr, search_term.len);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var customers = self.allocator.alloc(CustomerResult, row_count) catch {
            return ReviewError.OutOfMemory;
        };

        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);
            customers[i] = CustomerResult{
                .customer_id = c.duckdb_value_int64(&result, 0, row),
                .name = undefined,
            };

            const name_ptr = c.duckdb_value_varchar(&result, 1, row);
            if (name_ptr != null) {
                const name_len = @min(std.mem.len(name_ptr), 255);
                @memcpy(customers[i].name_buf[0..name_len], name_ptr[0..name_len]);
                customers[i].name = customers[i].name_buf[0..name_len];
                c.duckdb_free(name_ptr);
            } else {
                customers[i].name = "";
            }
        }

        return customers;
    }

    /// Get all projects for a customer
    pub fn getProjectsForCustomer(self: *Reviewer, customer_id: i64) ![]ProjectResult {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query = "SELECT project_id, name FROM projects WHERE customer_id = ? ORDER BY name";

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, customer_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var projects = self.allocator.alloc(ProjectResult, row_count) catch {
            return ReviewError.OutOfMemory;
        };

        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);
            projects[i] = ProjectResult{
                .project_id = c.duckdb_value_int64(&result, 0, row),
                .name = undefined,
            };

            const name_ptr = c.duckdb_value_varchar(&result, 1, row);
            if (name_ptr != null) {
                const name_len = @min(std.mem.len(name_ptr), 255);
                @memcpy(projects[i].name_buf[0..name_len], name_ptr[0..name_len]);
                projects[i].name = projects[i].name_buf[0..name_len];
                c.duckdb_free(name_ptr);
            } else {
                projects[i].name = "";
            }
        }

        return projects;
    }

    /// Get all phases for a project
    pub fn getPhasesForProject(self: *Reviewer, project_id: i64) ![]PhaseResult {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query = "SELECT phase_id, name FROM phases WHERE project_id = ? ORDER BY name";

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, project_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var phases = self.allocator.alloc(PhaseResult, row_count) catch {
            return ReviewError.OutOfMemory;
        };

        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);
            phases[i] = PhaseResult{
                .phase_id = c.duckdb_value_int64(&result, 0, row),
                .name = undefined,
            };

            const name_ptr = c.duckdb_value_varchar(&result, 1, row);
            if (name_ptr != null) {
                const name_len = @min(std.mem.len(name_ptr), 255);
                @memcpy(phases[i].name_buf[0..name_len], name_ptr[0..name_len]);
                phases[i].name = phases[i].name_buf[0..name_len];
                c.duckdb_free(name_ptr);
            } else {
                phases[i].name = "";
            }
        }

        return phases;
    }

    /// Get all activities for a phase
    pub fn getActivitiesForPhase(self: *Reviewer, phase_id: i64) ![]ActivityResult {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query = "SELECT activity_id, name FROM activities WHERE phase_id = ? ORDER BY name";

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, phase_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var activities = self.allocator.alloc(ActivityResult, row_count) catch {
            return ReviewError.OutOfMemory;
        };

        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);
            activities[i] = ActivityResult{
                .activity_id = c.duckdb_value_int64(&result, 0, row),
                .name = undefined,
            };

            const name_ptr = c.duckdb_value_varchar(&result, 1, row);
            if (name_ptr != null) {
                const name_len = @min(std.mem.len(name_ptr), 255);
                @memcpy(activities[i].name_buf[0..name_len], name_ptr[0..name_len]);
                activities[i].name = activities[i].name_buf[0..name_len];
                c.duckdb_free(name_ptr);
            } else {
                activities[i].name = "";
            }
        }

        return activities;
    }

    /// Get all kinds for an activity
    pub fn getKindsForActivity(self: *Reviewer, activity_id: i64) ![]KindResult {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query = "SELECT kind_id, name, billable FROM kinds WHERE activity_id = ? ORDER BY name";

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, activity_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var kinds = self.allocator.alloc(KindResult, row_count) catch {
            return ReviewError.OutOfMemory;
        };

        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);
            kinds[i] = KindResult{
                .kind_id = c.duckdb_value_int64(&result, 0, row),
                .name = undefined,
                .billable = c.duckdb_value_boolean(&result, 2, row),
            };

            const name_ptr = c.duckdb_value_varchar(&result, 1, row);
            if (name_ptr != null) {
                const name_len = @min(std.mem.len(name_ptr), 255);
                @memcpy(kinds[i].name_buf[0..name_len], name_ptr[0..name_len]);
                kinds[i].name = kinds[i].name_buf[0..name_len];
                c.duckdb_free(name_ptr);
            } else {
                kinds[i].name = "";
            }
        }

        return kinds;
    }

    /// Map an event to an activity and kind
    pub fn mapEvent(self: *Reviewer, event_id: i64, activity_id: i64, kind_id: i64, manually_mapped: bool) !void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query = "UPDATE events SET activity_id = ?, kind_id = ?, manually_mapped = ? WHERE id = ?";

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.UpdateFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, activity_id);
        _ = c.duckdb_bind_int64(stmt, 2, kind_id);
        _ = c.duckdb_bind_boolean(stmt, 3, manually_mapped);
        _ = c.duckdb_bind_int64(stmt, 4, event_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ReviewError.UpdateFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    /// Search the full hierarchy for a term (searches kind names, returns full path)
    pub fn searchFullHierarchy(self: *Reviewer, search_term: []const u8) ![]HierarchyMatch {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query =
            \\SELECT 
            \\  k.kind_id,
            \\  a.activity_id,
            \\  c.name || ' > ' || p.name || ' > ' || ph.name || ' > ' || a.name || ' > ' || k.name as display_path
            \\FROM kinds k
            \\JOIN activities a ON k.activity_id = a.activity_id
            \\JOIN phases ph ON a.phase_id = ph.phase_id
            \\JOIN projects p ON ph.project_id = p.project_id
            \\JOIN customers c ON p.customer_id = c.customer_id
            \\WHERE LOWER(k.name) LIKE '%' || LOWER(?) || '%'
            \\   OR LOWER(a.name) LIKE '%' || LOWER(?) || '%'
            \\   OR LOWER(ph.name) LIKE '%' || LOWER(?) || '%'
            \\   OR LOWER(p.name) LIKE '%' || LOWER(?) || '%'
            \\   OR LOWER(c.name) LIKE '%' || LOWER(?) || '%'
            \\ORDER BY c.name, p.name, ph.name, a.name, k.name
            \\LIMIT 20
        ;

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        // Bind search term 5 times (for each level)
        for (1..6) |i| {
            _ = c.duckdb_bind_varchar_length(stmt, @intCast(i), search_term.ptr, search_term.len);
        }

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var matches = self.allocator.alloc(HierarchyMatch, row_count) catch {
            return ReviewError.OutOfMemory;
        };

        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);

            const path_ptr = c.duckdb_value_varchar(&result, 2, row);
            const path_len = if (path_ptr != null) std.mem.len(path_ptr) else 0;
            const path_copy = self.allocator.alloc(u8, path_len) catch {
                // Clean up already allocated
                for (0..i) |j| {
                    self.allocator.free(matches[j].display_path);
                }
                self.allocator.free(matches);
                return ReviewError.OutOfMemory;
            };
            if (path_ptr != null) {
                @memcpy(path_copy, path_ptr[0..path_len]);
                c.duckdb_free(path_ptr);
            }

            matches[i] = HierarchyMatch{
                .kind_id = c.duckdb_value_int64(&result, 0, row),
                .activity_id = c.duckdb_value_int64(&result, 1, row),
                .display_path = path_copy,
            };
        }

        return matches;
    }
};
