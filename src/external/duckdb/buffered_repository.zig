const std = @import("std");
const Event = @import("domain_event").Event;
const DuckDbRepository = @import("legacy_repository").DuckDbRepository;

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
    last_event_time: i64,
    flush_delay_ns: u64,
    mutex: std.Thread.Mutex,

    // Flush timer thread
    flush_thread: ?std.Thread,
    should_stop: std.atomic.Value(bool),

    const Self = @This();
    const DEFAULT_FLUSH_DELAY_MS: u64 = 5000; // 5 seconds
    const MAX_BUFFER_SIZE: usize = 1000; // Force flush if buffer gets too large

    pub fn init(allocator: std.mem.Allocator, db_path: [:0]const u8) Self {
        return Self{
            .allocator = allocator,
            .db_path = db_path,
            .buffer = .{},
            .last_event_time = 0,
            .flush_delay_ns = DEFAULT_FLUSH_DELAY_MS * std.time.ns_per_ms,
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

        const buffered = BufferedEvent.fromEvent(event, duration_ms);
        self.buffer.append(self.allocator, buffered) catch {
            std.debug.print("BufferedRepository: Failed to buffer event\n", .{});
            return;
        };

        self.last_event_time = getTimestampMs();

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
            return;
        }

        // Open database connection
        var repo = DuckDbRepository.init(self.db_path.ptr) catch |err| {
            std.debug.print("BufferedRepository: Failed to open database: {}\n", .{err});
            return;
        };
        defer repo.deinit();

        // Flush all buffered events
        var flushed: usize = 0;
        for (self.buffer.items) |*buffered| {
            const event = buffered.toEvent();
            repo.save(event, buffered.duration_ms);
            flushed += 1;
        }

        if (flushed > 0) {
            std.debug.print("BufferedRepository: Flushed {d} events to database\n", .{flushed});
        }

        // Clear buffer
        self.buffer.clearRetainingCapacity();
    }

    /// Background thread that checks for flush conditions
    fn flushTimerLoop(self: *Self) void {
        const check_interval_ns: u64 = 500 * std.time.ns_per_ms; // Check every 500ms

        while (!self.should_stop.load(.acquire)) {
            sleepNs(check_interval_ns);

            // Check if we should flush
            const now = getTimestampMs();
            const last_event = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk self.last_event_time;
            };

            // Flush if enough time has passed since last event
            if (last_event > 0) {
                const elapsed_ms: i64 = now - last_event;
                const flush_delay_ms: i64 = @intCast(self.flush_delay_ns / std.time.ns_per_ms);
                if (elapsed_ms >= flush_delay_ms) {
                    self.flushToDb();
                }
            }
        }
    }

    /// Get the number of buffered events (for testing/debugging)
    pub fn bufferedCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.buffer.items.len;
    }
};
