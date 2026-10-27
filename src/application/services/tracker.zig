const std = @import("std");
const Event = @import("domain_event").Event;

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

/// Generic repository interface using function pointers
pub fn Repository(comptime Context: type) type {
    return struct {
        context: Context,
        saveFn: *const fn (Context, Event, i64) void,

        pub fn save(self: @This(), event: Event, duration_ms: i64) void {
            self.saveFn(self.context, event, duration_ms);
        }
    };
}

/// Owned, fixed-size buffers describing a single window (app/title/wifi).
const WindowBuf = struct {
    app_buf: [256]u8 = undefined,
    app_len: usize = 0,
    title_buf: [512]u8 = undefined,
    title_len: usize = 0,
    wifi_buf: [64]u8 = undefined,
    wifi_len: usize = 0,

    fn set(self: *WindowBuf, app_name: []const u8, title_text: []const u8, wifi_ssid: []const u8) void {
        self.app_len = @min(app_name.len, self.app_buf.len);
        self.title_len = @min(title_text.len, self.title_buf.len);
        self.wifi_len = @min(wifi_ssid.len, self.wifi_buf.len);
        @memcpy(self.app_buf[0..self.app_len], app_name[0..self.app_len]);
        @memcpy(self.title_buf[0..self.title_len], title_text[0..self.title_len]);
        @memcpy(self.wifi_buf[0..self.wifi_len], wifi_ssid[0..self.wifi_len]);
    }

    fn copyFrom(self: *WindowBuf, other: *const WindowBuf) void {
        self.set(other.app(), other.title(), other.wifi());
    }

    fn app(self: *const WindowBuf) []const u8 {
        return self.app_buf[0..self.app_len];
    }

    fn title(self: *const WindowBuf) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    fn wifi(self: *const WindowBuf) []const u8 {
        return self.wifi_buf[0..self.wifi_len];
    }

    /// Identity ignores wifi/timestamp, matching Event.eql semantics.
    fn matches(self: *const WindowBuf, other_app: []const u8, other_title: []const u8) bool {
        return std.mem.eql(u8, self.app(), other_app) and
            std.mem.eql(u8, self.title(), other_title);
    }
};

/// A window seen during the current sampling bucket and how long it was focused.
const BucketEntry = struct {
    window: WindowBuf = .{},
    accumulated_ms: i64 = 0,
};

/// Samples the focused window into 5-second buckets, then logs only the
/// "dominant" window (the one focused longest) of each bucket. Consecutive
/// buckets with the same dominant window are coalesced into a single event,
/// so quick window switches are filtered out and a steady window stays one row.
pub const Tracker = struct {
    repo_context: *anyopaque,
    saveFn: *const fn (*anyopaque, Event, i64) void,

    mutex: std.Thread.Mutex = .{},

    // Currently focused window and when it gained focus.
    current: WindowBuf = .{},
    has_focus: bool = false,
    focus_start_ms: i64 = 0,

    // Per-window focus time accumulated during the current bucket.
    bucket: [MAX_BUCKET_WINDOWS]BucketEntry = undefined,
    bucket_count: usize = 0,
    bucket_start_ms: ?i64 = null,

    // The dominant window currently being logged (extended until it changes).
    pending: WindowBuf = .{},
    has_pending: bool = false,
    pending_start_ms: i64 = 0,

    // Background timer that fires flushBucket every SAMPLE_INTERVAL_MS.
    sample_thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const Self = @This();
    const MAX_BUCKET_WINDOWS: usize = 16;
    const SAMPLE_INTERVAL_MS: i64 = 5000; // 5 second sampling bucket
    const TICK_CHECK_MS: u64 = 500;

    pub fn init(repo: anytype) Tracker {
        const Ptr = @TypeOf(repo);
        const wrapper = struct {
            fn save(ctx: *anyopaque, event: Event, duration_ms: i64) void {
                const ptr: Ptr = @ptrCast(@alignCast(ctx));
                ptr.save(event, duration_ms);
            }
        };
        return Tracker{
            .repo_context = @ptrCast(repo),
            .saveFn = wrapper.save,
        };
    }

    /// Stop the sample timer (if running) and flush the trailing pending window.
    pub fn deinit(self: *Self) void {
        self.should_stop.store(true, .release);
        if (self.sample_thread) |thread| {
            thread.join();
            self.sample_thread = null;
        }
        self.finish(getTimestampMs());
    }

    /// Start the background sampling timer thread.
    pub fn startSampleTimer(self: *Self) !void {
        self.mutex.lock();
        self.bucket_start_ms = getTimestampMs();
        self.mutex.unlock();
        self.sample_thread = try std.Thread.spawn(.{}, sampleTimerLoop, .{self});
    }

    pub fn onEvent(self: *Self, app: []const u8, title: []const u8, timestamp_ms: i64) void {
        self.onEventWithWifi(app, title, "", timestamp_ms);
    }

    pub fn onEventWithWifi(self: *Self, app: []const u8, title: []const u8, wifi: []const u8, timestamp_ms: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.bucket_start_ms == null) self.bucket_start_ms = timestamp_ms;

        // Credit the window we are leaving with its focus time, then switch.
        self.settleCurrentLocked(timestamp_ms);
        self.current.set(app, title, wifi);
        self.has_focus = true;
        self.focus_start_ms = timestamp_ms;
    }

    /// Close out the current bucket: pick the dominant window and, if it differs
    /// from the one we are logging, emit the previous one. Safe to call directly
    /// in tests; the timer thread calls it every SAMPLE_INTERVAL_MS.
    pub fn flushBucket(self: *Self, now_ms: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.flushBucketLocked(now_ms);
    }

    /// Flush the final partial bucket and emit the trailing pending window.
    pub fn finish(self: *Self, now_ms: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.flushBucketLocked(now_ms);
        if (self.has_pending) {
            self.emitPendingLocked(now_ms);
            self.has_pending = false;
        }
    }

    fn settleCurrentLocked(self: *Self, now_ms: i64) void {
        if (!self.has_focus) return;
        const elapsed = now_ms - self.focus_start_ms;
        if (elapsed > 0) self.addToBucketLocked(&self.current, elapsed);
    }

    fn addToBucketLocked(self: *Self, window: *const WindowBuf, ms: i64) void {
        for (self.bucket[0..self.bucket_count]) |*entry| {
            if (entry.window.matches(window.app(), window.title())) {
                entry.accumulated_ms += ms;
                return;
            }
        }
        if (self.bucket_count >= MAX_BUCKET_WINDOWS) return; // drop pathological overflow
        self.bucket[self.bucket_count] = .{};
        self.bucket[self.bucket_count].window.copyFrom(window);
        self.bucket[self.bucket_count].accumulated_ms = ms;
        self.bucket_count += 1;
    }

    fn dominantLocked(self: *Self) ?*BucketEntry {
        var best: ?*BucketEntry = null;
        for (self.bucket[0..self.bucket_count]) |*entry| {
            if (best == null or entry.accumulated_ms > best.?.accumulated_ms) {
                best = entry;
            }
        }
        return best;
    }

    fn flushBucketLocked(self: *Self, now_ms: i64) void {
        const bucket_start = self.bucket_start_ms orelse now_ms;
        self.settleCurrentLocked(now_ms);

        if (self.dominantLocked()) |dom| {
            if (self.has_pending and self.pending.matches(dom.window.app(), dom.window.title())) {
                // Same dominant window: extend the pending event, emit nothing.
            } else {
                if (self.has_pending) self.emitPendingLocked(bucket_start);
                self.pending.copyFrom(&dom.window);
                self.has_pending = true;
                self.pending_start_ms = bucket_start;
            }
        }

        // Reset the bucket for the next interval, keeping the current focus.
        self.bucket_count = 0;
        self.bucket_start_ms = now_ms;
        if (self.has_focus) self.focus_start_ms = now_ms;
    }

    fn emitPendingLocked(self: *Self, end_ms: i64) void {
        const event = Event{
            .timestamp_ms = self.pending_start_ms,
            .app_name = self.pending.app(),
            .window_title = self.pending.title(),
            .wifi_ssid = self.pending.wifi(),
        };
        self.saveFn(self.repo_context, event, end_ms - self.pending_start_ms);
    }

    fn sampleTimerLoop(self: *Self) void {
        var elapsed_ms: i64 = 0;
        while (!self.should_stop.load(.acquire)) {
            sleepNs(TICK_CHECK_MS * std.time.ns_per_ms);
            elapsed_ms += @intCast(TICK_CHECK_MS);
            if (elapsed_ms >= SAMPLE_INTERVAL_MS) {
                elapsed_ms = 0;
                self.flushBucket(getTimestampMs());
            }
        }
    }
};
