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

/// Grouped unmapped events (by app_name + window_title)
pub const GroupedEvent = struct {
    app_name: []const u8,
    window_title: []const u8,
    total_duration_ms: i64,
    event_count: i64,

    // Buffers for storing string data
    app_name_buf: [256]u8 = undefined,
    window_title_buf: [512]u8 = undefined,
};

/// Hourly aggregate of unmapped events for timeline highlighting
pub const HourBucket = struct {
    hour: u8,
    event_count: i64,
    total_duration_ms: i64,
};

/// Date string buffer type (YYYY-MM-DD format)
pub const DateString = struct {
    buf: [10]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const DateString) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Suggested rule based on pattern detection
pub const RuleSuggestion = struct {
    pub const SuggestionType = enum {
        app_only, // Match any title for this app
        app_and_title, // Match specific app + title pattern
    };

    suggestion_type: SuggestionType,

    // Pattern to match
    app_pattern: []const u8,
    title_pattern: ?[]const u8, // null for app_only

    // Target mapping
    activity_id: i64,
    kind_id: i64,
    display_path: []const u8, // "Customer > Project > Phase > Activity > Kind"

    // Scoring
    confidence: u8, // 0-100 percentage
    impact_count: u32, // Number of unmapped events this would map
    impact_duration_ms: i64, // Total duration affected

    // Evidence
    evidence_count: u32, // Number of mapped events supporting this

    // Buffers for string storage (owned by Analyzer)
    app_pattern_buf: [256]u8 = undefined,
    title_pattern_buf: [256]u8 = undefined,
    display_path_buf: [512]u8 = undefined,

    /// Format impact duration as human-readable string
    pub fn formatDuration(self: *const RuleSuggestion, buf: []u8) []const u8 {
        const total_seconds = @divFloor(self.impact_duration_ms, 1000);
        const hours = @divFloor(total_seconds, 3600);
        const minutes = @divFloor(@mod(total_seconds, 3600), 60);

        if (hours > 0) {
            return std.fmt.bufPrint(buf, "{d}h {d}m", .{ hours, minutes }) catch "?";
        } else {
            return std.fmt.bufPrint(buf, "{d}m", .{minutes}) catch "?";
        }
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
        return self.getDatesWithUnmappedEventsFiltered(0);
    }

    /// Get dates with unmapped events filtered by minimum duration (milliseconds)
    pub fn getDatesWithUnmappedEventsFiltered(self: *Reviewer, min_duration_ms: i64) ![]DateString {
        var result: c.duckdb_result = undefined;
        const query =
            \\SELECT DISTINCT DATE(TO_TIMESTAMP(timestamp_ms / 1000)) as event_date
            \\FROM events 
            \\WHERE activity_id IS NULL AND manually_mapped = false
            \\  AND duration_ms >= ?
            \\ORDER BY event_date DESC
        ;

        var stmt: c.duckdb_prepared_statement = undefined;
        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, min_duration_ms);

        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
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

    const SortOrder = enum {
        asc,
        desc,
    };

    /// Get unmapped events for a specific date (YYYY-MM-DD format), sorted newest first.
    pub fn getUnmappedEventsForDate(self: *Reviewer, date: []const u8) ![]UnmappedEvent {
        return self.getUnmappedEventsForDateWithOptions(date, 0, .desc);
    }

    /// Get unmapped events for a specific date with a minimum duration threshold.
    /// Returned in chronological order for timeline rendering.
    pub fn getUnmappedEventsForDateFiltered(self: *Reviewer, date: []const u8, min_duration_ms: i64) ![]UnmappedEvent {
        return self.getUnmappedEventsForDateWithOptions(date, min_duration_ms, .asc);
    }

    fn getUnmappedEventsForDateWithOptions(
        self: *Reviewer,
        date: []const u8,
        min_duration_ms: i64,
        sort: SortOrder,
    ) ![]UnmappedEvent {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query = switch (sort) {
            .asc =>
            \\SELECT id, timestamp_ms, app_name, window_title, duration_ms 
            \\FROM events 
            \\WHERE activity_id IS NULL AND manually_mapped = false
            \\  AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
            \\  AND duration_ms >= ?
            \\ORDER BY timestamp_ms ASC
            ,
            .desc =>
            \\SELECT id, timestamp_ms, app_name, window_title, duration_ms 
            \\FROM events 
            \\WHERE activity_id IS NULL AND manually_mapped = false
            \\  AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
            \\  AND duration_ms >= ?
            \\ORDER BY timestamp_ms DESC
            ,
        };

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_varchar_length(stmt, 1, date.ptr, date.len);
        _ = c.duckdb_bind_int64(stmt, 2, min_duration_ms);

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

    /// Get grouped unmapped events for a specific date (grouped by app_name + window_title)
    pub fn getGroupedEventsForDate(self: *Reviewer, date: []const u8) ![]GroupedEvent {
        return self.getGroupedEventsForDateFiltered(date, 0);
    }

    /// Get grouped unmapped events for a specific date with minimum duration filtering.
    pub fn getGroupedEventsForDateFiltered(self: *Reviewer, date: []const u8, min_duration_ms: i64) ![]GroupedEvent {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query =
            \\SELECT app_name, window_title, SUM(duration_ms) as total_duration, COUNT(*) as event_count
            \\FROM events 
            \\WHERE activity_id IS NULL AND manually_mapped = false
            \\  AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
            \\  AND duration_ms >= ?
            \\GROUP BY app_name, window_title
            \\ORDER BY total_duration DESC
        ;

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_varchar_length(stmt, 1, date.ptr, date.len);
        _ = c.duckdb_bind_int64(stmt, 2, min_duration_ms);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var groups = self.allocator.alloc(GroupedEvent, row_count) catch {
            return ReviewError.OutOfMemory;
        };

        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);

            groups[i] = GroupedEvent{
                .app_name = undefined,
                .window_title = undefined,
                .total_duration_ms = c.duckdb_value_int64(&result, 2, row),
                .event_count = c.duckdb_value_int64(&result, 3, row),
            };

            // Copy app_name
            const app_ptr = c.duckdb_value_varchar(&result, 0, row);
            if (app_ptr != null) {
                const app_len = @min(std.mem.len(app_ptr), 255);
                @memcpy(groups[i].app_name_buf[0..app_len], app_ptr[0..app_len]);
                groups[i].app_name = groups[i].app_name_buf[0..app_len];
                c.duckdb_free(app_ptr);
            } else {
                groups[i].app_name = "";
            }

            // Copy window_title
            const title_ptr = c.duckdb_value_varchar(&result, 1, row);
            if (title_ptr != null) {
                const title_len = @min(std.mem.len(title_ptr), 511);
                @memcpy(groups[i].window_title_buf[0..title_len], title_ptr[0..title_len]);
                groups[i].window_title = groups[i].window_title_buf[0..title_len];
                c.duckdb_free(title_ptr);
            } else {
                groups[i].window_title = "";
            }
        }

        return groups;
    }

    /// Get per-hour unmapped event totals for a specific date.
    pub fn getHourlyUnmappedSummaryForDate(self: *Reviewer, date: []const u8, min_duration_ms: i64) ![]HourBucket {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query =
            \\SELECT CAST(EXTRACT(hour FROM TO_TIMESTAMP(timestamp_ms / 1000)) AS INTEGER) as event_hour,
            \\       COUNT(*) as event_count,
            \\       COALESCE(SUM(duration_ms), 0) as total_duration
            \\FROM events
            \\WHERE activity_id IS NULL AND manually_mapped = false
            \\  AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
            \\  AND duration_ms >= ?
            \\GROUP BY event_hour
            \\ORDER BY event_hour ASC
        ;

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_varchar_length(stmt, 1, date.ptr, date.len);
        _ = c.duckdb_bind_int64(stmt, 2, min_duration_ms);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var buckets = self.allocator.alloc(HourBucket, row_count) catch {
            return ReviewError.OutOfMemory;
        };

        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);
            buckets[i] = HourBucket{
                .hour = @intCast(c.duckdb_value_int64(&result, 0, row)),
                .event_count = c.duckdb_value_int64(&result, 1, row),
                .total_duration_ms = c.duckdb_value_int64(&result, 2, row),
            };
        }

        return buckets;
    }

    /// Map all events matching app_name and window_title for a given date
    pub fn mapEventsByGroup(self: *Reviewer, date: []const u8, app_name: []const u8, window_title: []const u8, activity_id: i64, kind_id: i64) !void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query =
            \\UPDATE events 
            \\SET activity_id = ?, kind_id = ?, manually_mapped = true
            \\WHERE activity_id IS NULL AND manually_mapped = false
            \\  AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
            \\  AND app_name = ? AND window_title = ?
        ;

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.UpdateFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, activity_id);
        _ = c.duckdb_bind_int64(stmt, 2, kind_id);
        _ = c.duckdb_bind_varchar_length(stmt, 3, date.ptr, date.len);
        _ = c.duckdb_bind_varchar_length(stmt, 4, app_name.ptr, app_name.len);
        _ = c.duckdb_bind_varchar_length(stmt, 5, window_title.ptr, window_title.len);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ReviewError.UpdateFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    /// Discard all events matching app_name and window_title for a given date
    pub fn discardEventsByGroup(self: *Reviewer, date: []const u8, app_name: []const u8, window_title: []const u8) !void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query =
            \\UPDATE events 
            \\SET manually_mapped = true
            \\WHERE activity_id IS NULL AND manually_mapped = false
            \\  AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
            \\  AND app_name = ? AND window_title = ?
        ;

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.UpdateFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_varchar_length(stmt, 1, date.ptr, date.len);
        _ = c.duckdb_bind_varchar_length(stmt, 2, app_name.ptr, app_name.len);
        _ = c.duckdb_bind_varchar_length(stmt, 3, window_title.ptr, window_title.len);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ReviewError.UpdateFailed;
        }
        c.duckdb_destroy_result(&result);
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

    /// Map multiple events to an activity and kind
    pub fn mapEvents(self: *Reviewer, event_ids: []const i64, activity_id: i64, kind_id: i64) !void {
        for (event_ids) |event_id| {
            try self.mapEvent(event_id, activity_id, kind_id, true);
        }
    }

    /// Discard events (mark as manually_mapped but with no activity - non-work)
    pub fn discardEvents(self: *Reviewer, event_ids: []const i64) !void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query = "UPDATE events SET manually_mapped = true WHERE id = ?";

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.UpdateFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        for (event_ids) |event_id| {
            _ = c.duckdb_clear_bindings(stmt);
            _ = c.duckdb_bind_int64(stmt, 1, event_id);

            var result: c.duckdb_result = undefined;
            if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
                c.duckdb_destroy_result(&result);
                return ReviewError.UpdateFailed;
            }
            c.duckdb_destroy_result(&result);
        }
    }

    /// Discard a single event by id.
    pub fn discardEvent(self: *Reviewer, event_id: i64) !void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query =
            \\UPDATE events
            \\SET manually_mapped = true
            \\WHERE id = ?
            \\  AND activity_id IS NULL
            \\  AND manually_mapped = false
        ;

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.UpdateFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, event_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ReviewError.UpdateFailed;
        }
        c.duckdb_destroy_result(&result);
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

    /// Add a "follow previous" rule for an app (optionally with title pattern)
    /// If title_pattern is null, rule matches any title for this app
    pub fn addFollowPreviousRule(self: *Reviewer, app_pattern: []const u8, title_pattern: ?[]const u8) !void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query =
            \\INSERT INTO mapping_rules (priority, app_pattern, title_pattern, follow_previous)
            \\VALUES (0, ?, ?, true)
        ;

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.UpdateFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_varchar_length(stmt, 1, app_pattern.ptr, app_pattern.len);
        if (title_pattern) |tp| {
            _ = c.duckdb_bind_varchar_length(stmt, 2, tp.ptr, tp.len);
        } else {
            _ = c.duckdb_bind_null(stmt, 2);
        }

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ReviewError.UpdateFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    /// Apply all rules to unmapped events for a specific date
    /// Returns the number of events that were mapped
    pub fn applyRulesForDate(self: *Reviewer, date: []const u8) !u32 {
        // Get all events for the date, ordered by timestamp
        var stmt: c.duckdb_prepared_statement = undefined;
        const query =
            \\SELECT id, timestamp_ms, app_name, window_title, activity_id, kind_id
            \\FROM events
            \\WHERE DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
            \\ORDER BY timestamp_ms ASC
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
        var mapped_count: u32 = 0;

        // Track the previous event's mapping
        var prev_activity_id: ?i64 = null;
        var prev_kind_id: ?i64 = null;

        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);

            const event_id = c.duckdb_value_int64(&result, 0, row);
            const current_activity_id = c.duckdb_value_int64(&result, 4, row);
            const current_kind_id = c.duckdb_value_int64(&result, 5, row);

            // Check if already mapped
            const is_null_activity = c.duckdb_value_is_null(&result, 4, row);
            if (!is_null_activity) {
                // Already mapped - use as previous for next iteration
                prev_activity_id = current_activity_id;
                prev_kind_id = current_kind_id;
                continue;
            }

            // Get app_name and window_title
            const app_ptr = c.duckdb_value_varchar(&result, 2, row);
            const title_ptr = c.duckdb_value_varchar(&result, 3, row);
            defer {
                if (app_ptr != null) c.duckdb_free(app_ptr);
                if (title_ptr != null) c.duckdb_free(title_ptr);
            }

            const app_name = if (app_ptr != null) app_ptr[0..std.mem.len(app_ptr)] else "";
            const window_title = if (title_ptr != null) title_ptr[0..std.mem.len(title_ptr)] else "";

            // Try to find a matching rule
            if (try self.findMatchingRule(app_name, window_title)) |rule_match| {
                if (rule_match.follow_previous) {
                    // Follow previous: use prev_activity_id/prev_kind_id if available
                    if (prev_activity_id != null and prev_kind_id != null) {
                        try self.mapEvent(event_id, prev_activity_id.?, prev_kind_id.?, false);
                        mapped_count += 1;
                        // Don't update prev - keep using same context
                    }
                    // If no previous, leave unmapped
                } else {
                    // Regular rule with activity/kind
                    try self.mapEvent(event_id, rule_match.activity_id.?, rule_match.kind_id.?, false);
                    prev_activity_id = rule_match.activity_id;
                    prev_kind_id = rule_match.kind_id;
                    mapped_count += 1;
                }
            }
        }

        return mapped_count;
    }

    const RuleMatch = struct {
        activity_id: ?i64,
        kind_id: ?i64,
        follow_previous: bool,
    };

    /// Find a matching rule for the given app/title
    fn findMatchingRule(self: *Reviewer, app_name: []const u8, window_title: []const u8) !?RuleMatch {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query =
            \\SELECT activity_id, kind_id, follow_previous, is_global, kind_name
            \\FROM mapping_rules
            \\WHERE (app_pattern IS NULL OR ? GLOB app_pattern)
            \\  AND (title_pattern IS NULL OR ? GLOB title_pattern)
            \\ORDER BY priority DESC
            \\LIMIT 1
        ;

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_varchar_length(stmt, 1, app_name.ptr, app_name.len);
        _ = c.duckdb_bind_varchar_length(stmt, 2, window_title.ptr, window_title.len);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        if (c.duckdb_row_count(&result) == 0) {
            return null;
        }

        const follow_previous = c.duckdb_value_boolean(&result, 2, 0);

        if (follow_previous) {
            return RuleMatch{
                .activity_id = null,
                .kind_id = null,
                .follow_previous = true,
            };
        }

        const is_null_activity = c.duckdb_value_is_null(&result, 0, 0);
        if (is_null_activity) {
            return null; // Rule exists but has no mapping
        }

        return RuleMatch{
            .activity_id = c.duckdb_value_int64(&result, 0, 0),
            .kind_id = c.duckdb_value_int64(&result, 1, 0),
            .follow_previous = false,
        };
    }

    /// Analyze unmapped events for a date and suggest rules
    /// Returns suggestions sorted by impact (highest first)
    pub fn analyzeForDate(self: *Reviewer, date: []const u8) ![]RuleSuggestion {
        // Step 1: Get app-only suggestions (apps that consistently map to one activity/kind)
        const app_suggestions = try self.detectAppOnlyPatterns(date);
        defer self.allocator.free(app_suggestions);

        // Step 2: Get title pattern suggestions
        const title_suggestions = try self.detectTitlePatterns(date);
        defer self.allocator.free(title_suggestions);

        // Combine and sort by impact
        const total_len = app_suggestions.len + title_suggestions.len;
        if (total_len == 0) {
            return self.allocator.alloc(RuleSuggestion, 0) catch return ReviewError.OutOfMemory;
        }

        var all_suggestions = self.allocator.alloc(RuleSuggestion, total_len) catch {
            return ReviewError.OutOfMemory;
        };

        // Copy app suggestions
        for (app_suggestions, 0..) |suggestion, i| {
            all_suggestions[i] = suggestion;
        }

        // Copy title suggestions
        for (title_suggestions, 0..) |suggestion, i| {
            all_suggestions[app_suggestions.len + i] = suggestion;
        }

        // Sort by impact_duration_ms descending
        std.mem.sort(RuleSuggestion, all_suggestions, {}, struct {
            fn lessThan(_: void, a: RuleSuggestion, b: RuleSuggestion) bool {
                return a.impact_duration_ms > b.impact_duration_ms;
            }
        }.lessThan);

        // Limit to 10 suggestions
        if (all_suggestions.len > 10) {
            const trimmed = self.allocator.alloc(RuleSuggestion, 10) catch {
                return ReviewError.OutOfMemory;
            };
            @memcpy(trimmed, all_suggestions[0..10]);
            self.allocator.free(all_suggestions);
            return trimmed;
        }

        return all_suggestions;
    }

    /// Detect apps that consistently map to the same activity/kind
    fn detectAppOnlyPatterns(self: *Reviewer, date: []const u8) ![]RuleSuggestion {
        // Find apps with >80% consistency in mapping
        var result: c.duckdb_result = undefined;
        const query =
            \\WITH app_mappings AS (
            \\    SELECT 
            \\        app_name,
            \\        activity_id,
            \\        kind_id,
            \\        COUNT(*) as match_count,
            \\        SUM(duration_ms) as total_duration
            \\    FROM events
            \\    WHERE activity_id IS NOT NULL 
            \\      AND manually_mapped = true
            \\    GROUP BY app_name, activity_id, kind_id
            \\),
            \\app_totals AS (
            \\    SELECT app_name, SUM(match_count) as total_count
            \\    FROM app_mappings
            \\    GROUP BY app_name
            \\),
            \\app_confidence AS (
            \\    SELECT 
            \\        m.app_name,
            \\        m.activity_id,
            \\        m.kind_id,
            \\        m.match_count,
            \\        m.total_duration,
            \\        CAST(m.match_count * 100.0 / t.total_count AS INTEGER) as confidence
            \\    FROM app_mappings m
            \\    JOIN app_totals t ON m.app_name = t.app_name
            \\    WHERE m.match_count * 100.0 / t.total_count >= 80
            \\)
            \\SELECT 
            \\    ac.app_name,
            \\    ac.activity_id,
            \\    ac.kind_id,
            \\    ac.match_count as evidence_count,
            \\    ac.confidence,
            \\    c.name || ' > ' || p.name || ' > ' || ph.name || ' > ' || a.name || ' > ' || k.name as display_path
            \\FROM app_confidence ac
            \\JOIN activities a ON ac.activity_id = a.activity_id
            \\JOIN kinds k ON ac.activity_id = k.activity_id AND ac.kind_id = k.kind_id
            \\JOIN phases ph ON a.phase_id = ph.phase_id
            \\JOIN projects p ON ph.project_id = p.project_id
            \\JOIN customers c ON p.customer_id = c.customer_id
            \\ORDER BY ac.match_count DESC
            \\LIMIT 20
        ;

        if (c.duckdb_query(self.conn, query, &result) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var suggestions = self.allocator.alloc(RuleSuggestion, row_count) catch {
            return ReviewError.OutOfMemory;
        };

        var valid_count: usize = 0;
        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);

            // Get app_name
            const app_ptr = c.duckdb_value_varchar(&result, 0, row);
            if (app_ptr == null) continue;
            defer c.duckdb_free(app_ptr);

            const app_name = app_ptr[0..std.mem.len(app_ptr)];

            // Check if there are unmapped events for this app on this date
            const impact = self.getUnmappedImpact(date, app_name, null) catch continue;
            if (impact.count == 0) continue;

            // Build suggestion
            suggestions[valid_count] = RuleSuggestion{
                .suggestion_type = .app_only,
                .app_pattern = undefined,
                .title_pattern = null,
                .activity_id = c.duckdb_value_int64(&result, 1, row),
                .kind_id = c.duckdb_value_int64(&result, 2, row),
                .display_path = undefined,
                .confidence = @intCast(c.duckdb_value_int64(&result, 4, row)),
                .impact_count = impact.count,
                .impact_duration_ms = impact.duration_ms,
                .evidence_count = @intCast(c.duckdb_value_int64(&result, 3, row)),
            };

            // Copy app_pattern
            const app_len = @min(app_name.len, 255);
            @memcpy(suggestions[valid_count].app_pattern_buf[0..app_len], app_name[0..app_len]);
            suggestions[valid_count].app_pattern = suggestions[valid_count].app_pattern_buf[0..app_len];

            // Copy display_path
            const path_ptr = c.duckdb_value_varchar(&result, 5, row);
            if (path_ptr != null) {
                const path_len = @min(std.mem.len(path_ptr), 511);
                @memcpy(suggestions[valid_count].display_path_buf[0..path_len], path_ptr[0..path_len]);
                suggestions[valid_count].display_path = suggestions[valid_count].display_path_buf[0..path_len];
                c.duckdb_free(path_ptr);
            } else {
                suggestions[valid_count].display_path = "";
            }

            valid_count += 1;
        }

        // Shrink to valid count
        if (valid_count < suggestions.len) {
            const trimmed = self.allocator.alloc(RuleSuggestion, valid_count) catch {
                return ReviewError.OutOfMemory;
            };
            @memcpy(trimmed, suggestions[0..valid_count]);
            self.allocator.free(suggestions);
            return trimmed;
        }

        return suggestions;
    }

    /// Detect title patterns from mapped events
    fn detectTitlePatterns(self: *Reviewer, date: []const u8) ![]RuleSuggestion {
        // Find common title patterns from mapped events
        // Strategy: extract first segment of title (before " - " or " | ")
        var result: c.duckdb_result = undefined;
        const query =
            \\WITH title_segments AS (
            \\    SELECT 
            \\        app_name,
            \\        CASE 
            \\            WHEN POSITION(' - ' IN window_title) > 0 
            \\            THEN SUBSTRING(window_title, 1, POSITION(' - ' IN window_title) - 1)
            \\            WHEN POSITION(' | ' IN window_title) > 0 
            \\            THEN SUBSTRING(window_title, 1, POSITION(' | ' IN window_title) - 1)
            \\            ELSE window_title
            \\        END as title_segment,
            \\        activity_id,
            \\        kind_id,
            \\        duration_ms
            \\    FROM events
            \\    WHERE activity_id IS NOT NULL 
            \\      AND manually_mapped = true
            \\      AND LENGTH(window_title) > 0
            \\),
            \\segment_mappings AS (
            \\    SELECT 
            \\        app_name,
            \\        title_segment,
            \\        activity_id,
            \\        kind_id,
            \\        COUNT(*) as match_count,
            \\        SUM(duration_ms) as total_duration
            \\    FROM title_segments
            \\    WHERE LENGTH(title_segment) >= 3
            \\    GROUP BY app_name, title_segment, activity_id, kind_id
            \\    HAVING COUNT(*) >= 3
            \\)
            \\SELECT 
            \\    sm.app_name,
            \\    sm.title_segment,
            \\    sm.activity_id,
            \\    sm.kind_id,
            \\    sm.match_count as evidence_count,
            \\    c.name || ' > ' || p.name || ' > ' || ph.name || ' > ' || a.name || ' > ' || k.name as display_path
            \\FROM segment_mappings sm
            \\JOIN activities a ON sm.activity_id = a.activity_id
            \\JOIN kinds k ON sm.activity_id = k.activity_id AND sm.kind_id = k.kind_id
            \\JOIN phases ph ON a.phase_id = ph.phase_id
            \\JOIN projects p ON ph.project_id = p.project_id
            \\JOIN customers c ON p.customer_id = c.customer_id
            \\ORDER BY sm.match_count DESC
            \\LIMIT 20
        ;

        if (c.duckdb_query(self.conn, query, &result) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var suggestions = self.allocator.alloc(RuleSuggestion, row_count) catch {
            return ReviewError.OutOfMemory;
        };

        var valid_count: usize = 0;
        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);

            // Get app_name
            const app_ptr = c.duckdb_value_varchar(&result, 0, row);
            if (app_ptr == null) continue;
            defer c.duckdb_free(app_ptr);
            const app_name = app_ptr[0..std.mem.len(app_ptr)];

            // Get title_segment
            const segment_ptr = c.duckdb_value_varchar(&result, 1, row);
            if (segment_ptr == null) continue;
            defer c.duckdb_free(segment_ptr);
            const title_segment = segment_ptr[0..std.mem.len(segment_ptr)];

            // Build glob pattern: *segment*
            var pattern_buf: [260]u8 = undefined;
            const pattern = std.fmt.bufPrint(&pattern_buf, "*{s}*", .{title_segment}) catch continue;

            // Check if there are unmapped events matching this pattern on this date
            const impact = self.getUnmappedImpactByPattern(date, app_name, pattern) catch continue;
            if (impact.count == 0) continue;

            // Build suggestion
            suggestions[valid_count] = RuleSuggestion{
                .suggestion_type = .app_and_title,
                .app_pattern = undefined,
                .title_pattern = undefined,
                .activity_id = c.duckdb_value_int64(&result, 2, row),
                .kind_id = c.duckdb_value_int64(&result, 3, row),
                .display_path = undefined,
                .confidence = 85, // Title patterns get 85% confidence
                .impact_count = impact.count,
                .impact_duration_ms = impact.duration_ms,
                .evidence_count = @intCast(c.duckdb_value_int64(&result, 4, row)),
            };

            // Copy app_pattern
            const app_len = @min(app_name.len, 255);
            @memcpy(suggestions[valid_count].app_pattern_buf[0..app_len], app_name[0..app_len]);
            suggestions[valid_count].app_pattern = suggestions[valid_count].app_pattern_buf[0..app_len];

            // Copy title_pattern
            const pattern_len = @min(pattern.len, 255);
            @memcpy(suggestions[valid_count].title_pattern_buf[0..pattern_len], pattern[0..pattern_len]);
            suggestions[valid_count].title_pattern = suggestions[valid_count].title_pattern_buf[0..pattern_len];

            // Copy display_path
            const path_ptr = c.duckdb_value_varchar(&result, 5, row);
            if (path_ptr != null) {
                const path_len = @min(std.mem.len(path_ptr), 511);
                @memcpy(suggestions[valid_count].display_path_buf[0..path_len], path_ptr[0..path_len]);
                suggestions[valid_count].display_path = suggestions[valid_count].display_path_buf[0..path_len];
                c.duckdb_free(path_ptr);
            } else {
                suggestions[valid_count].display_path = "";
            }

            valid_count += 1;
        }

        // Shrink to valid count
        if (valid_count < suggestions.len) {
            const trimmed = self.allocator.alloc(RuleSuggestion, valid_count) catch {
                return ReviewError.OutOfMemory;
            };
            @memcpy(trimmed, suggestions[0..valid_count]);
            self.allocator.free(suggestions);
            return trimmed;
        }

        return suggestions;
    }

    const ImpactResult = struct {
        count: u32,
        duration_ms: i64,
    };

    /// Get count and duration of unmapped events matching app (and optionally title)
    fn getUnmappedImpact(self: *Reviewer, date: []const u8, app_name: []const u8, title: ?[]const u8) !ImpactResult {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query = if (title != null)
            \\SELECT COUNT(*), COALESCE(SUM(duration_ms), 0)
            \\FROM events
            \\WHERE activity_id IS NULL AND manually_mapped = false
            \\  AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
            \\  AND app_name = ? AND window_title = ?
        else
            \\SELECT COUNT(*), COALESCE(SUM(duration_ms), 0)
            \\FROM events
            \\WHERE activity_id IS NULL AND manually_mapped = false
            \\  AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
            \\  AND app_name = ?
        ;

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_varchar_length(stmt, 1, date.ptr, date.len);
        _ = c.duckdb_bind_varchar_length(stmt, 2, app_name.ptr, app_name.len);
        if (title) |t| {
            _ = c.duckdb_bind_varchar_length(stmt, 3, t.ptr, t.len);
        }

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        return ImpactResult{
            .count = @intCast(c.duckdb_value_int64(&result, 0, 0)),
            .duration_ms = c.duckdb_value_int64(&result, 1, 0),
        };
    }

    /// Get count and duration of unmapped events matching app and title pattern (glob)
    fn getUnmappedImpactByPattern(self: *Reviewer, date: []const u8, app_name: []const u8, title_pattern: []const u8) !ImpactResult {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query =
            \\SELECT COUNT(*), COALESCE(SUM(duration_ms), 0)
            \\FROM events
            \\WHERE activity_id IS NULL AND manually_mapped = false
            \\  AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
            \\  AND app_name = ?
            \\  AND window_title GLOB ?
        ;

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_varchar_length(stmt, 1, date.ptr, date.len);
        _ = c.duckdb_bind_varchar_length(stmt, 2, app_name.ptr, app_name.len);
        _ = c.duckdb_bind_varchar_length(stmt, 3, title_pattern.ptr, title_pattern.len);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return ReviewError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        return ImpactResult{
            .count = @intCast(c.duckdb_value_int64(&result, 0, 0)),
            .duration_ms = c.duckdb_value_int64(&result, 1, 0),
        };
    }

    /// Create a rule from a suggestion and optionally apply to unmapped events
    pub fn acceptSuggestion(self: *Reviewer, suggestion: RuleSuggestion, apply_now: bool, date: []const u8) !u32 {
        // Create the rule
        var stmt: c.duckdb_prepared_statement = undefined;
        const query =
            \\INSERT INTO mapping_rules (priority, app_pattern, title_pattern, activity_id, kind_id)
            \\VALUES (0, ?, ?, ?, ?)
        ;

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.UpdateFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_varchar_length(stmt, 1, suggestion.app_pattern.ptr, suggestion.app_pattern.len);
        if (suggestion.title_pattern) |tp| {
            _ = c.duckdb_bind_varchar_length(stmt, 2, tp.ptr, tp.len);
        } else {
            _ = c.duckdb_bind_null(stmt, 2);
        }
        _ = c.duckdb_bind_int64(stmt, 3, suggestion.activity_id);
        _ = c.duckdb_bind_int64(stmt, 4, suggestion.kind_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ReviewError.UpdateFailed;
        }
        c.duckdb_destroy_result(&result);

        // Apply to existing events if requested
        if (apply_now) {
            return try self.applyRuleToUnmapped(
                date,
                suggestion.app_pattern,
                suggestion.title_pattern,
                suggestion.activity_id,
                suggestion.kind_id,
            );
        }

        return 0;
    }

    /// Apply a rule pattern to unmapped events for a date
    fn applyRuleToUnmapped(self: *Reviewer, date: []const u8, app_pattern: []const u8, title_pattern: ?[]const u8, activity_id: i64, kind_id: i64) !u32 {
        var stmt: c.duckdb_prepared_statement = undefined;
        const query = if (title_pattern != null)
            \\UPDATE events
            \\SET activity_id = ?, kind_id = ?, manually_mapped = false
            \\WHERE activity_id IS NULL AND manually_mapped = false
            \\  AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
            \\  AND app_name = ?
            \\  AND window_title GLOB ?
        else
            \\UPDATE events
            \\SET activity_id = ?, kind_id = ?, manually_mapped = false
            \\WHERE activity_id IS NULL AND manually_mapped = false
            \\  AND DATE(TO_TIMESTAMP(timestamp_ms / 1000)) = ?
            \\  AND app_name = ?
        ;

        if (c.duckdb_prepare(self.conn, query, &stmt) == c.DuckDBError) {
            return ReviewError.UpdateFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, activity_id);
        _ = c.duckdb_bind_int64(stmt, 2, kind_id);
        _ = c.duckdb_bind_varchar_length(stmt, 3, date.ptr, date.len);
        _ = c.duckdb_bind_varchar_length(stmt, 4, app_pattern.ptr, app_pattern.len);
        if (title_pattern) |tp| {
            _ = c.duckdb_bind_varchar_length(stmt, 5, tp.ptr, tp.len);
        }

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return ReviewError.UpdateFailed;
        }

        const rows_changed = c.duckdb_rows_changed(&result);
        c.duckdb_destroy_result(&result);

        return @intCast(rows_changed);
    }
};
