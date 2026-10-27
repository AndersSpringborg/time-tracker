//! Delivery of outbox records to the backend ingestion socket.
//!
//! Records are removed only after the backend reports the sequence it has
//! committed, so a lost response or an unreachable backend causes a resend
//! rather than lost time. A permanent rejection is surfaced to the caller
//! instead of being acknowledged silently.
const std = @import("std");
const Event = @import("domain_event").Event;
const outbox = @import("outbox.zig");

pub const Response = struct {
    status: u16,
    retryable: bool,
    acknowledged_sequence: u64,
};

/// Transport boundary: sends one encoded batch and returns the backend reply.
pub const Transport = struct {
    ptr: *anyopaque,
    send: *const fn (*anyopaque, body: []const u8) anyerror!Response,
};

pub const Outcome = enum {
    /// Nothing to send.
    idle,
    /// The backend committed at least part of the batch.
    delivered,
    /// Transient failure; the same records are resent after the retry delay.
    retry_later,
    /// The backend refused the batch permanently; records are kept for
    /// inspection rather than discarded.
    rejected,
};

pub const default_max_batch = 64;
const base_retry_ms: u64 = 1000;
const max_retry_ms: u64 = 60 * 1000;
const max_body_len = default_max_batch * (outbox.max_text_len * 3 + 256) + 128;
/// The backend permanently rejects a batch holding an interval outside
/// (0, one day]. Such intervals come from sleep spans and wall-clock steps; sent
/// as recorded, one would be resent forever and block every record behind it.
const min_duration_ms: i64 = 1;
const max_duration_ms: i64 = std.time.ms_per_day;

pub const Delivery = struct {
    outbox: *outbox.Outbox,
    transport: Transport,
    max_batch: usize = default_max_batch,
    consecutive_failures: u32 = 0,

    const Self = @This();

    /// Send one bounded batch and acknowledge whatever the backend committed.
    pub fn deliverPending(self: *Self) !Outcome {
        var records: [default_max_batch]outbox.Record = undefined;
        const limit = @min(self.max_batch, records.len);
        const pending = self.outbox.pending(records[0..limit]);
        if (pending.len == 0) {
            self.consecutive_failures = 0;
            return .idle;
        }

        var body_buffer: [max_body_len]u8 = undefined;
        const body = try encodeBatch(&body_buffer, self.outbox.producerId(), pending);

        const response = self.transport.send(self.transport.ptr, body) catch {
            self.consecutive_failures +|= 1;
            return .retry_later;
        };
        if (response.status != 200) {
            if (response.retryable) {
                self.consecutive_failures +|= 1;
                return .retry_later;
            }
            self.consecutive_failures = 0;
            return .rejected;
        }

        self.consecutive_failures = 0;
        try self.outbox.acknowledge(response.acknowledged_sequence);
        return .delivered;
    }

    /// How long to wait before the next attempt; zero once delivery succeeds.
    pub fn retryDelayMs(self: Self) u64 {
        if (self.consecutive_failures == 0) return 0;
        const shift: u6 = @intCast(@min(self.consecutive_failures - 1, 6));
        return @min(base_retry_ms << shift, max_retry_ms);
    }
};

fn encodeBatch(
    buffer: []u8,
    producer_id: [outbox.producer_id_len]u8,
    records: []const outbox.Record,
) ![]u8 {
    var writer = std.Io.Writer.fixed(buffer);
    var stringify = std.json.Stringify{ .writer = &writer };
    try stringify.beginObject();
    try stringify.objectField("producer_id");
    try stringify.write(&std.fmt.bytesToHex(producer_id, .lower));
    try stringify.objectField("intervals");
    try stringify.beginArray();
    for (records) |record| {
        try stringify.write(.{
            .sequence = record.sequence,
            .timestamp_ms = record.timestamp_ms,
            .duration_ms = std.math.clamp(record.duration_ms, min_duration_ms, max_duration_ms),
            .app_name = record.app_name,
            .window_title = record.window_title,
            .wifi_ssid = record.wifi_ssid,
        });
    }
    try stringify.endArray();
    try stringify.endObject();
    return writer.buffered();
}
