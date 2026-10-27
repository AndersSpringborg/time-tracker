//! The worker's event sink: a durable outbox plus a background delivery loop.
//!
//! This replaces the worker's direct DuckDB writes. The worker no longer opens
//! the database at all, which removes the checkpoint-per-flush that regrew the
//! file by roughly 160 MB a day, and makes the backend the sole owner of it.
//!
//! `save` does nothing but append durably, so the capture path never waits on
//! the network. Delivery runs on its own thread and only ever removes records
//! the backend has reported as committed.
const std = @import("std");
const Event = @import("domain_event").Event;
const outbox = @import("outbox.zig");
const delivery = @import("delivery.zig");

/// Re-exported so the worker depends on one module for its event sink.
pub const SocketTransport = @import("socket_transport.zig").SocketTransport;

pub const Options = struct {
    outbox: outbox.Options = .{},
    /// How often to offer pending records to the backend.
    delivery_interval_ms: u64 = 5_000,
    max_batch: usize = delivery.default_max_batch,
};

pub const OutboxRepository = struct {
    box: outbox.Outbox,
    transport: delivery.Transport,
    max_batch: usize,
    /// Carried across delivery attempts so an outage backs off instead of
    /// reconnecting in a tight loop.
    consecutive_failures: u32 = 0,
    /// Guards the outbox; held for an append or an acknowledgement, never for
    /// the transport round trip beyond the bounded batch the sender performs.
    mutex: std.Thread.Mutex = .{},
    /// The last reason an interval could not be recorded, for the menu to show.
    /// Cleared as soon as recording succeeds again.
    recording_error: ?anyerror = null,

    delivery_interval_ms: u64,
    delivery_thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const Self = @This();
    const tick_ms: u64 = 100;

    pub fn init(
        allocator: std.mem.Allocator,
        path: []const u8,
        transport: delivery.Transport,
        options: Options,
    ) !Self {
        return Self{
            .box = try outbox.Outbox.open(allocator, path, options.outbox),
            .transport = transport,
            .max_batch = options.max_batch,
            .delivery_interval_ms = options.delivery_interval_ms,
        };
    }

    /// Stop delivering, make a last attempt at whatever is pending, and close.
    pub fn deinit(self: *Self) void {
        self.should_stop.store(true, .release);
        if (self.delivery_thread) |thread| {
            thread.join();
            self.delivery_thread = null;
        }
        _ = self.deliverNow() catch {};
        self.box.deinit();
    }

    /// Tracker repository contract: record one completed interval.
    pub fn save(self: *Self, event: Event, duration_ms: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.box.append(event, duration_ms) catch |err| {
            self.recording_error = err;
            return;
        };
        self.recording_error = null;
    }

    pub fn deliverNow(self: *Self) !delivery.Outcome {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Built per call so nothing holds a pointer into a moved value; the
        // only state worth carrying is the failure count.
        var sender = delivery.Delivery{
            .outbox = &self.box,
            .transport = self.transport,
            .max_batch = self.max_batch,
            .consecutive_failures = self.consecutive_failures,
        };
        defer self.consecutive_failures = sender.consecutive_failures;
        return sender.deliverPending();
    }

    /// How long the delivery loop waits after the latest attempt.
    pub fn retryDelayMs(self: *Self) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sender = delivery.Delivery{
            .outbox = &self.box,
            .transport = self.transport,
            .max_batch = self.max_batch,
            .consecutive_failures = self.consecutive_failures,
        };
        return sender.retryDelayMs();
    }

    pub fn pendingCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.box.pendingCount();
    }

    pub fn recordingError(self: *Self) ?anyerror {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.recording_error;
    }

    pub fn startDeliveryTimer(self: *Self) !void {
        self.delivery_thread = try std.Thread.spawn(.{}, deliveryLoop, .{self});
    }

    fn deliveryLoop(self: *Self) void {
        var waited_ms: u64 = 0;
        var wait_for_ms = self.delivery_interval_ms;
        while (!self.should_stop.load(.acquire)) {
            std.posix.nanosleep(0, tick_ms * std.time.ns_per_ms);
            waited_ms += tick_ms;
            if (waited_ms < wait_for_ms) continue;
            waited_ms = 0;

            const outcome = self.deliverNow() catch delivery.Outcome.retry_later;
            // Back off while the backend is down, so an outage does not turn
            // into a tight reconnect loop.
            const backoff_ms = self.retryDelayMs();
            wait_for_ms = switch (outcome) {
                .retry_later => @max(backoff_ms, self.delivery_interval_ms),
                else => self.delivery_interval_ms,
            };
        }
    }
};
