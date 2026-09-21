const std = @import("std");
const Event = @import("domain_event").Event;
const migrations = @import("migrations");
const Migrator = migrations.Migrator;
const c = migrations.c;

/// Get current time in milliseconds
fn getTimestampMs() i64 {
    const ts = std.posix.clock_gettime(.REALTIME) catch return 0;
    const sec_ms: i64 = ts.sec * 1000;
    const nsec_ms: i64 = @divFloor(ts.nsec, 1_000_000);
    return sec_ms + nsec_ms;
}

/// Sleep for the specified number of nanoseconds
fn sleepNs(ns: u64) void {
    const seconds = ns / std.time.ns_per_s;
    const nanoseconds = ns % std.time.ns_per_s;
    std.posix.nanosleep(seconds, nanoseconds);
}

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

/// Owns a DuckDB connection for the duration of a single flush. The buffered
/// repository opens one of these per flush and closes it immediately after, so
/// other processes (e.g. the manager) can access the database between flushes.
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

    /// Begin an explicit transaction so a batch of saves commits once,
    /// rather than each insert running in its own implicit transaction.
    pub fn beginTransaction(self: *DuckDbRepository) void {
        self.execQuery("BEGIN TRANSACTION") catch {
            std.debug.print("Failed to begin transaction\n", .{});
        };
    }

    /// Commit the explicit transaction opened by beginTransaction.
    pub fn commitTransaction(self: *DuckDbRepository) void {
        self.execQuery("COMMIT") catch {
            std.debug.print("Failed to commit transaction\n", .{});
        };
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

/// A buffered event with its duration
pub const BufferedEvent = struct {
    timestamp_ms: i64,
    duration_ms: i64,
    app_name_buf: [256]u8,
    app_name_len: usize,
    window_title_buf: [512]u8,
    window_title_len: usize,
    wifi_ssid_buf: [64]u8,
    wifi_ssid_len: usize,

    pub fn fromEvent(event: Event, duration_ms: i64) BufferedEvent {
        var buffered = BufferedEvent{
            .timestamp_ms = event.timestamp_ms,
            .duration_ms = duration_ms,
            .app_name_buf = undefined,
            .app_name_len = @min(event.app_name.len, 256),
            .window_title_buf = undefined,
            .window_title_len = @min(event.window_title.len, 512),
            .wifi_ssid_buf = undefined,
            .wifi_ssid_len = @min(event.wifi_ssid.len, 64),
        };

        @memcpy(buffered.app_name_buf[0..buffered.app_name_len], event.app_name[0..buffered.app_name_len]);
        @memcpy(buffered.window_title_buf[0..buffered.window_title_len], event.window_title[0..buffered.window_title_len]);
        @memcpy(buffered.wifi_ssid_buf[0..buffered.wifi_ssid_len], event.wifi_ssid[0..buffered.wifi_ssid_len]);

        return buffered;
    }

    pub fn toEvent(self: *const BufferedEvent) Event {
        return Event{
            .timestamp_ms = self.timestamp_ms,
            .app_name = self.app_name_buf[0..self.app_name_len],
            .window_title = self.window_title_buf[0..self.window_title_len],
            .wifi_ssid = self.wifi_ssid_buf[0..self.wifi_ssid_len],
        };
    }
};

/// Repository that buffers events in memory and flushes to DB periodically.
/// Releases the DB connection after flushing, allowing other processes to access it.
pub const BufferedRepository = struct {
    allocator: std.mem.Allocator,
    db_path: [:0]const u8,
    buffer: std.ArrayListUnmanaged(BufferedEvent),
    flush_interval_ns: u64,
    mutex: std.Thread.Mutex,

    // Flush timer thread
    flush_thread: ?std.Thread,
    should_stop: std.atomic.Value(bool),

    const Self = @This();
    const FLUSH_INTERVAL_MS: u64 = 5 * 60 * 1000; // 5 minutes
    pub const MIN_BUFFER_CAPACITY: usize = 64; // keep small steady-state reservation
    const MAX_BUFFER_SIZE: usize = 1000; // Force flush if buffer gets too large

    pub fn init(allocator: std.mem.Allocator, db_path: [:0]const u8) Self {
        return Self{
            .allocator = allocator,
            .db_path = db_path,
            .buffer = .{},
            .flush_interval_ns = FLUSH_INTERVAL_MS * std.time.ns_per_ms,
            .mutex = .{},
            .flush_thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        // Signal thread to stop and wait
        self.should_stop.store(true, .release);
        if (self.flush_thread) |thread| {
            thread.join();
        }

        // Final flush
        self.flushToDb();
        self.buffer.deinit(self.allocator);
    }

    /// Start the background flush timer thread
    pub fn startFlushTimer(self: *Self) !void {
        self.flush_thread = try std.Thread.spawn(.{}, flushTimerLoop, .{self});
    }

    /// Save an event to the buffer (called from tracker)
    pub fn save(self: *Self, event: Event, duration_ms: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.ensureMinCapacityLocked();

        const buffered = BufferedEvent.fromEvent(event, duration_ms);
        self.buffer.append(self.allocator, buffered) catch {
            std.debug.print("BufferedRepository: Failed to buffer event\n", .{});
            return;
        };

        // Force flush if buffer is too large
        if (self.buffer.items.len >= MAX_BUFFER_SIZE) {
            self.flushToDbLocked();
        }
    }

    /// Flush buffer to database (acquires lock)
    pub fn flushToDb(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.flushToDbLocked();
    }

    /// Flush buffer to database (must hold lock)
    fn flushToDbLocked(self: *Self) void {
        if (self.buffer.items.len == 0) {
            self.ensureMinCapacityLocked();
            return;
        }

        // Open database connection
        var repo = DuckDbRepository.init(self.db_path.ptr) catch |err| {
            std.debug.print("BufferedRepository: Failed to open database: {}\n", .{err});
            return;
        };
        defer repo.deinit();

        const buffered_count = self.buffer.items.len;
        const previous_capacity = self.buffer.capacity;

        // Flush all buffered events in a single transaction so the batch
        // commits (and checkpoints on close) once, instead of one implicit
        // transaction per row.
        repo.beginTransaction();
        var flushed: usize = 0;
        for (self.buffer.items) |*buffered| {
            const event = buffered.toEvent();
            repo.save(event, buffered.duration_ms);
            flushed += 1;
        }
        repo.commitTransaction();

        // Clear buffered items and return capacity to a small steady-state baseline.
        self.buffer.clearAndFree(self.allocator);
        self.ensureMinCapacityLocked();

        std.debug.print(
            "BufferedRepository: Flushed {d}/{d} events to database (capacity {d} -> {d})\n",
            .{ flushed, buffered_count, previous_capacity, self.buffer.capacity },
        );
    }

    /// Background thread that flushes the buffer on a fixed interval, regardless
    /// of activity. The DB connection is opened and closed per flush.
    fn flushTimerLoop(self: *Self) void {
        const check_interval_ns: u64 = 500 * std.time.ns_per_ms; // Check every 500ms
        const flush_interval_ms: i64 = @intCast(self.flush_interval_ns / std.time.ns_per_ms);
        var last_flush = getTimestampMs();

        while (!self.should_stop.load(.acquire)) {
            sleepNs(check_interval_ns);

            const now = getTimestampMs();
            if (now - last_flush >= flush_interval_ms) {
                self.flushToDb(); // no-op when the buffer is empty
                last_flush = now;
            }
        }
    }

    /// Get the number of buffered events (for testing/debugging)
    pub fn bufferedCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.buffer.items.len;
    }

    /// Get the current buffer capacity (for testing/debugging).
    pub fn bufferedCapacity(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.buffer.capacity;
    }

    fn ensureMinCapacityLocked(self: *Self) void {
        if (self.buffer.capacity >= MIN_BUFFER_CAPACITY) {
            return;
        }
        self.buffer.ensureTotalCapacityPrecise(self.allocator, MIN_BUFFER_CAPACITY) catch {
            std.debug.print(
                "BufferedRepository: Failed to reserve minimum capacity ({d})\n",
                .{MIN_BUFFER_CAPACITY},
            );
        };
    }
};
