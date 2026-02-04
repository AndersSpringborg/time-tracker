const std = @import("std");
const Event = @import("domain_event").Event;
const event_repository = @import("event_repository");
const EventRepository = event_repository.EventRepository;
const StoredEvent = event_repository.StoredEvent;
const RuleMatch = event_repository.RuleMatch;
const migrations = @import("migrations");
const c = migrations.c;

/// DuckDB implementation of EventRepository.
pub const DuckDbEventRepository = struct {
    conn: c.duckdb_connection,
    allocator: std.mem.Allocator,

    // Internal buffer for last event
    last_event_buf: LastEventBuf = .{},

    const LastEventBuf = struct {
        app_name_buf: [256]u8 = undefined,
        window_title_buf: [512]u8 = undefined,
        wifi_ssid_buf: [64]u8 = undefined,
    };

    pub fn init(conn: c.duckdb_connection, allocator: std.mem.Allocator) DuckDbEventRepository {
        return .{
            .conn = conn,
            .allocator = allocator,
        };
    }

    pub fn save(self: *DuckDbEventRepository, event: Event, duration_ms: i64, match: ?RuleMatch) void {
        var stmt: c.duckdb_prepared_statement = undefined;

        const insert_sql = if (match != null)
            "INSERT INTO events (timestamp_ms, app_name, window_title, wifi_ssid, duration_ms, activity_id, kind_id) VALUES (?, ?, ?, ?, ?, ?, ?)"
        else
            "INSERT INTO events (timestamp_ms, app_name, window_title, wifi_ssid, duration_ms) VALUES (?, ?, ?, ?, ?)";

        if (c.duckdb_prepare(self.conn, insert_sql, &stmt) == c.DuckDBError) {
            return;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, event.timestamp_ms);
        _ = c.duckdb_bind_varchar_length(stmt, 2, event.app_name.ptr, event.app_name.len);
        _ = c.duckdb_bind_varchar_length(stmt, 3, event.window_title.ptr, event.window_title.len);
        _ = c.duckdb_bind_varchar_length(stmt, 4, event.wifi_ssid.ptr, event.wifi_ssid.len);
        _ = c.duckdb_bind_int64(stmt, 5, duration_ms);

        if (match) |m| {
            _ = c.duckdb_bind_int64(stmt, 6, m.activity_id);
            _ = c.duckdb_bind_int64(stmt, 7, m.kind_id);
        }

        var result: c.duckdb_result = undefined;
        _ = c.duckdb_execute_prepared(stmt, &result);
        c.duckdb_destroy_result(&result);
    }

    pub fn getLastEvent(self: *DuckDbEventRepository) ?StoredEvent {
        var result: c.duckdb_result = undefined;

        const query = "SELECT id, timestamp_ms, app_name, window_title, wifi_ssid, duration_ms, activity_id, kind_id, manually_mapped FROM events ORDER BY id DESC LIMIT 1";
        if (c.duckdb_query(self.conn, query, &result) == c.DuckDBError) {
            return null;
        }
        defer c.duckdb_destroy_result(&result);

        if (c.duckdb_row_count(&result) == 0) {
            return null;
        }

        // Get string values and copy to internal buffers
        const app_ptr = c.duckdb_value_varchar(&result, 2, 0);
        var app_len: usize = 0;
        if (app_ptr != null) {
            app_len = std.mem.len(app_ptr);
            @memcpy(self.last_event_buf.app_name_buf[0..app_len], app_ptr[0..app_len]);
            c.duckdb_free(app_ptr);
        }

        const title_ptr = c.duckdb_value_varchar(&result, 3, 0);
        var title_len: usize = 0;
        if (title_ptr != null) {
            title_len = std.mem.len(title_ptr);
            @memcpy(self.last_event_buf.window_title_buf[0..title_len], title_ptr[0..title_len]);
            c.duckdb_free(title_ptr);
        }

        const wifi_ptr = c.duckdb_value_varchar(&result, 4, 0);
        var wifi_len: usize = 0;
        if (wifi_ptr != null) {
            wifi_len = std.mem.len(wifi_ptr);
            @memcpy(self.last_event_buf.wifi_ssid_buf[0..wifi_len], wifi_ptr[0..wifi_len]);
            c.duckdb_free(wifi_ptr);
        }

        return StoredEvent{
            .id = c.duckdb_value_int64(&result, 0, 0),
            .timestamp_ms = c.duckdb_value_int64(&result, 1, 0),
            .app_name = self.last_event_buf.app_name_buf[0..app_len],
            .window_title = self.last_event_buf.window_title_buf[0..title_len],
            .wifi_ssid = self.last_event_buf.wifi_ssid_buf[0..wifi_len],
            .duration_ms = c.duckdb_value_int64(&result, 5, 0),
            .activity_id = if (c.duckdb_value_is_null(&result, 6, 0)) null else c.duckdb_value_int64(&result, 6, 0),
            .kind_id = if (c.duckdb_value_is_null(&result, 7, 0)) null else c.duckdb_value_int64(&result, 7, 0),
            .manually_mapped = c.duckdb_value_boolean(&result, 8, 0),
        };
    }

    pub fn countEvents(self: *DuckDbEventRepository) i64 {
        var result: c.duckdb_result = undefined;

        if (c.duckdb_query(self.conn, "SELECT COUNT(*) FROM events", &result) == c.DuckDBError) {
            return 0;
        }
        defer c.duckdb_destroy_result(&result);

        return c.duckdb_value_int64(&result, 0, 0);
    }

    /// Convert to the interface type.
    pub fn repository(self: *DuckDbEventRepository) EventRepository {
        return EventRepository{
            .ptr = self,
            .vtable = &.{
                .save = saveVtable,
                .getLastEvent = getLastEventVtable,
                .countEvents = countEventsVtable,
            },
        };
    }

    fn saveVtable(ptr: *anyopaque, event: Event, duration_ms: i64, match: ?RuleMatch) void {
        const self: *DuckDbEventRepository = @ptrCast(@alignCast(ptr));
        self.save(event, duration_ms, match);
    }

    fn getLastEventVtable(ptr: *anyopaque) ?StoredEvent {
        const self: *DuckDbEventRepository = @ptrCast(@alignCast(ptr));
        return self.getLastEvent();
    }

    fn countEventsVtable(ptr: *anyopaque) i64 {
        const self: *DuckDbEventRepository = @ptrCast(@alignCast(ptr));
        return self.countEvents();
    }
};
