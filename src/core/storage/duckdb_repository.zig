const std = @import("std");
const Event = @import("event").Event;
const migrations = @import("migrations");
const Migrator = migrations.Migrator;
const c = migrations.c;

pub const DuckDbError = error{
    OpenFailed,
    ConnectFailed,
    QueryFailed,
    NoResults,
};

pub const StoredEvent = struct {
    app_name: []const u8,
    window_title: []const u8,
    wifi_ssid: []const u8,
    duration_ms: i64,

    // Buffers for storing string data
    app_name_buf: [256]u8 = undefined,
    window_title_buf: [512]u8 = undefined,
    wifi_ssid_buf: [64]u8 = undefined,
};

pub const DuckDbRepository = struct {
    db: c.duckdb_database,
    conn: c.duckdb_connection,

    pub fn initInMemory() DuckDbError!DuckDbRepository {
        return init(":memory:");
    }

    pub fn init(path: [*c]const u8) DuckDbError!DuckDbRepository {
        var db: c.duckdb_database = undefined;
        var conn: c.duckdb_connection = undefined;

        if (c.duckdb_open(path, &db) == c.DuckDBError) {
            return DuckDbError.OpenFailed;
        }

        if (c.duckdb_connect(db, &conn) == c.DuckDBError) {
            c.duckdb_close(&db);
            return DuckDbError.ConnectFailed;
        }

        // Run migrations
        var migrator = Migrator.init(conn) catch {
            c.duckdb_disconnect(&conn);
            c.duckdb_close(&db);
            return DuckDbError.QueryFailed;
        };
        migrator.run() catch {
            c.duckdb_disconnect(&conn);
            c.duckdb_close(&db);
            return DuckDbError.QueryFailed;
        };

        return DuckDbRepository{
            .db = db,
            .conn = conn,
        };
    }

    pub fn deinit(self: *DuckDbRepository) void {
        c.duckdb_disconnect(&self.conn);
        c.duckdb_close(&self.db);
    }

    pub fn save(self: *DuckDbRepository, event: Event, duration_ms: i64) void {
        // Use prepared statement to avoid SQL injection
        var stmt: c.duckdb_prepared_statement = undefined;

        const insert_sql = "INSERT INTO events (timestamp_ms, app_name, window_title, wifi_ssid, duration_ms) VALUES (?, ?, ?, ?, ?)";

        if (c.duckdb_prepare(self.conn, insert_sql, &stmt) == c.DuckDBError) {
            std.debug.print("Failed to prepare insert statement\n", .{});
            return;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        // Bind parameters
        _ = c.duckdb_bind_int64(stmt, 1, event.timestamp_ms);
        _ = c.duckdb_bind_varchar_length(stmt, 2, event.app_name.ptr, event.app_name.len);
        _ = c.duckdb_bind_varchar_length(stmt, 3, event.window_title.ptr, event.window_title.len);
        _ = c.duckdb_bind_varchar_length(stmt, 4, event.wifi_ssid.ptr, event.wifi_ssid.len);
        _ = c.duckdb_bind_int64(stmt, 5, duration_ms);

        // Execute
        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            std.debug.print("Failed to execute insert: {s}\n", .{c.duckdb_result_error(&result)});
        }
        c.duckdb_destroy_result(&result);
    }

    pub fn countEvents(self: *DuckDbRepository) DuckDbError!usize {
        var result: c.duckdb_result = undefined;

        if (c.duckdb_query(self.conn, "SELECT COUNT(*) FROM events", &result) == c.DuckDBError) {
            return DuckDbError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const count = c.duckdb_value_int64(&result, 0, 0);
        return @intCast(count);
    }

    pub fn getLastEvent(self: *DuckDbRepository) DuckDbError!StoredEvent {
        var result: c.duckdb_result = undefined;

        const query = "SELECT app_name, window_title, wifi_ssid, duration_ms FROM events ORDER BY id DESC LIMIT 1";
        if (c.duckdb_query(self.conn, query, &result) == c.DuckDBError) {
            return DuckDbError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        if (row_count == 0) {
            return DuckDbError.NoResults;
        }

        var stored = StoredEvent{
            .app_name = undefined,
            .window_title = undefined,
            .wifi_ssid = undefined,
            .duration_ms = 0,
        };

        // Get app_name (column 0)
        const app_name_ptr = c.duckdb_value_varchar(&result, 0, 0);
        if (app_name_ptr != null) {
            const app_name_len = std.mem.len(app_name_ptr);
            @memcpy(stored.app_name_buf[0..app_name_len], app_name_ptr[0..app_name_len]);
            stored.app_name = stored.app_name_buf[0..app_name_len];
            c.duckdb_free(app_name_ptr);
        }

        // Get window_title (column 1)
        const title_ptr = c.duckdb_value_varchar(&result, 1, 0);
        if (title_ptr != null) {
            const title_len = std.mem.len(title_ptr);
            @memcpy(stored.window_title_buf[0..title_len], title_ptr[0..title_len]);
            stored.window_title = stored.window_title_buf[0..title_len];
            c.duckdb_free(title_ptr);
        }

        // Get wifi_ssid (column 2)
        const wifi_ptr = c.duckdb_value_varchar(&result, 2, 0);
        if (wifi_ptr != null) {
            const wifi_len = std.mem.len(wifi_ptr);
            @memcpy(stored.wifi_ssid_buf[0..wifi_len], wifi_ptr[0..wifi_len]);
            stored.wifi_ssid = stored.wifi_ssid_buf[0..wifi_len];
            c.duckdb_free(wifi_ptr);
        }

        // Get duration_ms (column 3)
        stored.duration_ms = c.duckdb_value_int64(&result, 3, 0);

        return stored;
    }

    fn execQuery(self: *DuckDbRepository, sql: [*c]const u8) DuckDbError!void {
        var result: c.duckdb_result = undefined;
        if (c.duckdb_query(self.conn, sql, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return DuckDbError.QueryFailed;
        }
        c.duckdb_destroy_result(&result);
    }
};
