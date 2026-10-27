//! Durable, bounded client outbox.
//!
//! Activity intervals are appended to a single file and synchronised before the
//! append is reported as recorded, so a crash loses at most the record being
//! written. Each record carries a monotonic sequence; the backend acknowledges
//! a sequence only after it has committed, and only then is local data dropped.
//! Sequences are never reused, so a replayed batch is recognised as a duplicate
//! rather than counted twice.
//!
//! File layout (version 1):
//!   header: magic[8] | producer_id[16] | next_sequence u64 | reserved[32]
//!   record: payload_len u32 | crc32 u32 | payload
//!   payload: sequence u64 | timestamp_ms i64 | duration_ms i64
//!            | app_len u16 | title_len u16 | wifi_len u16 | bytes
const std = @import("std");
const Event = @import("domain_event").Event;

pub const magic = "TTOBOX01";
pub const producer_id_len = 16;
pub const header_len = 64;

const sequence_offset = magic.len + producer_id_len;
const record_prefix_len = 8;
const payload_fixed_len = 8 + 8 + 8 + 2 + 2 + 2;
pub const max_text_len = 1024;

pub const Error = error{
    OutboxFull,
    CorruptHeader,
    TextTooLong,
};

/// A pending interval. Its string fields point into outbox-owned memory and
/// stay valid until the next append or acknowledge.
pub const Record = struct {
    sequence: u64,
    timestamp_ms: i64,
    duration_ms: i64,
    app_name: []const u8,
    window_title: []const u8,
    wifi_ssid: []const u8,
};

pub const Options = struct {
    /// Upper bound on the file, including the header. Reaching it surfaces a
    /// recording error instead of silently discarding unsent activity.
    max_bytes: u64 = 32 * 1024 * 1024,
};

const PendingRecord = struct {
    sequence: u64,
    timestamp_ms: i64,
    duration_ms: i64,
    text: []u8,
    app_len: usize,
    title_len: usize,
    wifi_len: usize,

    fn toRecord(self: PendingRecord) Record {
        const title_end = self.app_len + self.title_len;
        return Record{
            .sequence = self.sequence,
            .timestamp_ms = self.timestamp_ms,
            .duration_ms = self.duration_ms,
            .app_name = self.text[0..self.app_len],
            .window_title = self.text[self.app_len..title_end],
            .wifi_ssid = self.text[title_end .. title_end + self.wifi_len],
        };
    }

    fn encodedLen(self: PendingRecord) u64 {
        return record_prefix_len + payload_fixed_len + self.text.len;
    }
};

pub const Outbox = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    file: std.fs.File,
    producer_id: [producer_id_len]u8,
    next_sequence: u64,
    pending_records: std.ArrayListUnmanaged(PendingRecord),
    file_len: u64,
    max_bytes: u64,

    const Self = @This();

    /// Open or create the outbox at path, recovering pending records and
    /// discarding an incomplete or corrupted trailing record.
    pub fn open(allocator: std.mem.Allocator, path: []const u8, options: Options) !Self {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        const file = try std.fs.cwd().createFile(owned_path, .{ .read = true, .truncate = false });
        errdefer file.close();

        var self = Self{
            .allocator = allocator,
            .path = owned_path,
            .file = file,
            .producer_id = undefined,
            .next_sequence = 1,
            .pending_records = .{},
            .file_len = 0,
            .max_bytes = options.max_bytes,
        };
        errdefer self.clearPending();

        if (try file.getEndPos() < header_len) {
            try self.writeNewHeader();
        } else {
            try self.readHeader();
            try self.recoverRecords();
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.clearPending();
        self.pending_records.deinit(self.allocator);
        self.file.close();
        self.allocator.free(self.path);
    }

    pub fn producerId(self: Self) [producer_id_len]u8 {
        return self.producer_id;
    }

    pub fn pendingCount(self: Self) usize {
        return self.pending_records.items.len;
    }

    pub fn byteSize(self: Self) u64 {
        return self.file_len;
    }

    /// Record an interval durably and return its sequence.
    pub fn append(self: *Self, event: Event, duration_ms: i64) !u64 {
        if (event.app_name.len > max_text_len or event.window_title.len > max_text_len or
            event.wifi_ssid.len > max_text_len)
        {
            return Error.TextTooLong;
        }
        const text_len = event.app_name.len + event.window_title.len + event.wifi_ssid.len;
        const encoded_len: u64 = record_prefix_len + payload_fixed_len + text_len;
        if (self.file_len + encoded_len > self.max_bytes) return Error.OutboxFull;

        const sequence = self.next_sequence;
        var buffer: [record_prefix_len + payload_fixed_len + 3 * max_text_len]u8 = undefined;
        const encoded = encodeRecord(&buffer, sequence, event, duration_ms);

        try self.file.seekTo(self.file_len);
        try self.file.writeAll(encoded);
        // Publish the sequence before the record is durable would risk reuse
        // after a crash, so the header advances first and both are synced.
        try self.writeNextSequence(sequence + 1);
        try self.file.sync();

        const record = try self.clonePending(sequence, event, duration_ms);
        errdefer self.freePending(record);
        try self.pending_records.append(self.allocator, record);

        self.file_len += encoded_len;
        self.next_sequence = sequence + 1;
        return sequence;
    }

    /// Fill out with pending records in sequence order, oldest first.
    pub fn pending(self: *Self, out: []Record) []Record {
        const count = @min(out.len, self.pending_records.items.len);
        for (self.pending_records.items[0..count], 0..) |record, i| out[i] = record.toRecord();
        return out[0..count];
    }

    /// Drop every record up to and including sequence, after the backend has
    /// committed them. The file is rewritten so acknowledged bytes are reclaimed.
    pub fn acknowledge(self: *Self, sequence: u64) !void {
        var keep: usize = 0;
        for (self.pending_records.items) |record| {
            if (record.sequence > sequence) break;
            keep += 1;
        }
        if (keep == 0) return;
        for (self.pending_records.items[0..keep]) |record| self.freePending(record);
        const remaining = self.pending_records.items.len - keep;
        std.mem.copyForwards(
            PendingRecord,
            self.pending_records.items[0..remaining],
            self.pending_records.items[keep..],
        );
        self.pending_records.shrinkRetainingCapacity(remaining);
        try self.rewrite();
    }

    fn rewrite(self: *Self) !void {
        var length: u64 = header_len;
        try self.file.seekTo(header_len);
        var buffer: [record_prefix_len + payload_fixed_len + 3 * max_text_len]u8 = undefined;
        for (self.pending_records.items) |record| {
            const source = record.toRecord();
            const encoded = encodeRecord(&buffer, record.sequence, Event{
                .timestamp_ms = source.timestamp_ms,
                .app_name = source.app_name,
                .window_title = source.window_title,
                .wifi_ssid = source.wifi_ssid,
            }, source.duration_ms);
            try self.file.writeAll(encoded);
            length += encoded.len;
        }
        try self.file.setEndPos(length);
        try self.file.sync();
        self.file_len = length;
    }

    fn clonePending(self: *Self, sequence: u64, event: Event, duration_ms: i64) !PendingRecord {
        const text = try self.allocator.alloc(u8, event.app_name.len + event.window_title.len + event.wifi_ssid.len);
        @memcpy(text[0..event.app_name.len], event.app_name);
        @memcpy(text[event.app_name.len..][0..event.window_title.len], event.window_title);
        @memcpy(text[event.app_name.len + event.window_title.len ..][0..event.wifi_ssid.len], event.wifi_ssid);
        return PendingRecord{
            .sequence = sequence,
            .timestamp_ms = event.timestamp_ms,
            .duration_ms = duration_ms,
            .text = text,
            .app_len = event.app_name.len,
            .title_len = event.window_title.len,
            .wifi_len = event.wifi_ssid.len,
        };
    }

    fn freePending(self: *Self, record: PendingRecord) void {
        self.allocator.free(record.text);
    }

    fn clearPending(self: *Self) void {
        for (self.pending_records.items) |record| self.freePending(record);
        self.pending_records.clearRetainingCapacity();
    }

    fn writeNewHeader(self: *Self) !void {
        std.crypto.random.bytes(&self.producer_id);
        var header: [header_len]u8 = @splat(0);
        @memcpy(header[0..magic.len], magic);
        @memcpy(header[magic.len..][0..producer_id_len], &self.producer_id);
        std.mem.writeInt(u64, header[sequence_offset..][0..8], 1, .little);
        try self.file.seekTo(0);
        try self.file.writeAll(&header);
        try self.file.setEndPos(header_len);
        try self.file.sync();
        self.next_sequence = 1;
        self.file_len = header_len;
    }

    fn readHeader(self: *Self) !void {
        var header: [header_len]u8 = undefined;
        if (try self.file.preadAll(&header, 0) != header_len) return Error.CorruptHeader;
        if (!std.mem.eql(u8, header[0..magic.len], magic)) return Error.CorruptHeader;
        @memcpy(&self.producer_id, header[magic.len..][0..producer_id_len]);
        self.next_sequence = std.mem.readInt(u64, header[sequence_offset..][0..8], .little);
        if (self.next_sequence == 0) return Error.CorruptHeader;
    }

    fn writeNextSequence(self: *Self, sequence: u64) !void {
        var encoded: [8]u8 = undefined;
        std.mem.writeInt(u64, &encoded, sequence, .little);
        try self.file.seekTo(sequence_offset);
        try self.file.writeAll(&encoded);
    }

    /// Read every intact record. Scanning stops at the first truncated or
    /// corrupted record, and the file is trimmed back to the last good one.
    fn recoverRecords(self: *Self) !void {
        const end = try self.file.getEndPos();
        var offset: u64 = header_len;
        var prefix: [record_prefix_len]u8 = undefined;
        var payload_buffer: [payload_fixed_len + 3 * max_text_len]u8 = undefined;

        while (offset + record_prefix_len <= end) {
            if (try self.file.preadAll(&prefix, offset) != record_prefix_len) break;
            const payload_len = std.mem.readInt(u32, prefix[0..4], .little);
            const checksum = std.mem.readInt(u32, prefix[4..8], .little);
            if (payload_len < payload_fixed_len or payload_len > payload_buffer.len) break;
            if (offset + record_prefix_len + payload_len > end) break;

            const payload = payload_buffer[0..payload_len];
            if (try self.file.preadAll(payload, offset + record_prefix_len) != payload_len) break;
            if (std.hash.Crc32.hash(payload) != checksum) break;

            const record = decodePayload(payload) orelse break;
            const cloned = try self.clonePending(record.sequence, Event{
                .timestamp_ms = record.timestamp_ms,
                .app_name = record.app_name,
                .window_title = record.window_title,
                .wifi_ssid = record.wifi_ssid,
            }, record.duration_ms);
            errdefer self.freePending(cloned);
            try self.pending_records.append(self.allocator, cloned);

            offset += record_prefix_len + payload_len;
            if (record.sequence >= self.next_sequence) self.next_sequence = record.sequence + 1;
        }

        self.file_len = offset;
        if (offset != end) {
            try self.file.setEndPos(offset);
            try self.file.sync();
        }
    }
};

fn encodeRecord(buffer: []u8, sequence: u64, event: Event, duration_ms: i64) []u8 {
    const payload = buffer[record_prefix_len..];
    std.mem.writeInt(u64, payload[0..8], sequence, .little);
    std.mem.writeInt(i64, payload[8..16], event.timestamp_ms, .little);
    std.mem.writeInt(i64, payload[16..24], duration_ms, .little);
    std.mem.writeInt(u16, payload[24..26], @intCast(event.app_name.len), .little);
    std.mem.writeInt(u16, payload[26..28], @intCast(event.window_title.len), .little);
    std.mem.writeInt(u16, payload[28..30], @intCast(event.wifi_ssid.len), .little);
    var cursor: usize = payload_fixed_len;
    for ([_][]const u8{ event.app_name, event.window_title, event.wifi_ssid }) |text| {
        @memcpy(payload[cursor..][0..text.len], text);
        cursor += text.len;
    }
    std.mem.writeInt(u32, buffer[0..4], @intCast(cursor), .little);
    std.mem.writeInt(u32, buffer[4..8], std.hash.Crc32.hash(payload[0..cursor]), .little);
    return buffer[0 .. record_prefix_len + cursor];
}

fn decodePayload(payload: []const u8) ?Record {
    const app_len = std.mem.readInt(u16, payload[24..26], .little);
    const title_len = std.mem.readInt(u16, payload[26..28], .little);
    const wifi_len = std.mem.readInt(u16, payload[28..30], .little);
    if (payload_fixed_len + @as(usize, app_len) + title_len + wifi_len != payload.len) return null;
    const app_start = payload_fixed_len;
    const title_start = app_start + app_len;
    const wifi_start = title_start + title_len;
    return Record{
        .sequence = std.mem.readInt(u64, payload[0..8], .little),
        .timestamp_ms = std.mem.readInt(i64, payload[8..16], .little),
        .duration_ms = std.mem.readInt(i64, payload[16..24], .little),
        .app_name = payload[app_start..title_start],
        .window_title = payload[title_start..wifi_start],
        .wifi_ssid = payload[wifi_start..],
    };
}
