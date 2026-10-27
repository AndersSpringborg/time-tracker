const std = @import("std");
const Event = @import("domain_event").Event;
const outbox = @import("outbox.zig");
const Outbox = outbox.Outbox;

const testing = std.testing;

fn testEvent(timestamp_ms: i64, app: []const u8) Event {
    return Event{
        .timestamp_ms = timestamp_ms,
        .app_name = app,
        .window_title = "window",
        .wifi_ssid = "Office",
    };
}

/// Each test gets its own directory so outbox files never collide.
const TempDir = struct {
    dir: std.testing.TmpDir,
    path: []u8,

    fn init(allocator: std.mem.Allocator) !TempDir {
        var dir = std.testing.tmpDir(.{});
        errdefer dir.cleanup();
        const path = try dir.dir.realpathAlloc(allocator, ".");
        return TempDir{ .dir = dir, .path = path };
    }

    fn file(self: TempDir, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.path, name });
    }

    fn deinit(self: *TempDir, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.dir.cleanup();
    }
};

test "appended intervals are readable with monotonic sequences" {
    const allocator = testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.deinit(allocator);
    const path = try tmp.file(allocator, "outbox.log");
    defer allocator.free(path);

    var box = try Outbox.open(allocator, path, .{});
    defer box.deinit();

    try testing.expectEqual(@as(u64, 1), try box.append(testEvent(1000, "Editor"), 5000));
    try testing.expectEqual(@as(u64, 2), try box.append(testEvent(6000, "Browser"), 3000));

    var batch: [8]outbox.Record = undefined;
    const pending = box.pending(&batch);
    try testing.expectEqual(@as(usize, 2), pending.len);
    try testing.expectEqual(@as(u64, 1), pending[0].sequence);
    try testing.expectEqual(@as(i64, 1000), pending[0].timestamp_ms);
    try testing.expectEqual(@as(i64, 5000), pending[0].duration_ms);
    try testing.expectEqualStrings("Editor", pending[0].app_name);
    try testing.expectEqualStrings("window", pending[0].window_title);
    try testing.expectEqualStrings("Office", pending[0].wifi_ssid);
    try testing.expectEqualStrings("Browser", pending[1].app_name);
}

test "pending returns at most the caller's batch size" {
    const allocator = testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.deinit(allocator);
    const path = try tmp.file(allocator, "outbox.log");
    defer allocator.free(path);

    var box = try Outbox.open(allocator, path, .{});
    defer box.deinit();
    for (0..5) |i| _ = try box.append(testEvent(@intCast(i * 1000), "Editor"), 1000);

    var batch: [2]outbox.Record = undefined;
    const pending = box.pending(&batch);
    try testing.expectEqual(@as(usize, 2), pending.len);
    try testing.expectEqual(@as(u64, 1), pending[0].sequence);
    try testing.expectEqual(@as(u64, 2), pending[1].sequence);
}

test "acknowledgement drops delivered records and keeps later ones" {
    const allocator = testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.deinit(allocator);
    const path = try tmp.file(allocator, "outbox.log");
    defer allocator.free(path);

    var box = try Outbox.open(allocator, path, .{});
    defer box.deinit();
    _ = try box.append(testEvent(1000, "Editor"), 1000);
    _ = try box.append(testEvent(2000, "Browser"), 1000);
    _ = try box.append(testEvent(3000, "Terminal"), 1000);

    try box.acknowledge(2);

    var batch: [8]outbox.Record = undefined;
    const pending = box.pending(&batch);
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqual(@as(u64, 3), pending[0].sequence);
    try testing.expectEqualStrings("Terminal", pending[0].app_name);
}

test "reopening recovers unacknowledged records, producer identity and sequence" {
    const allocator = testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.deinit(allocator);
    const path = try tmp.file(allocator, "outbox.log");
    defer allocator.free(path);

    var producer_id: [outbox.producer_id_len]u8 = undefined;
    {
        var box = try Outbox.open(allocator, path, .{});
        defer box.deinit();
        _ = try box.append(testEvent(1000, "Editor"), 1000);
        _ = try box.append(testEvent(2000, "Browser"), 1000);
        try box.acknowledge(1);
        producer_id = box.producerId();
    }

    var box = try Outbox.open(allocator, path, .{});
    defer box.deinit();
    try testing.expectEqualSlices(u8, &producer_id, &box.producerId());

    var batch: [8]outbox.Record = undefined;
    const pending = box.pending(&batch);
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqual(@as(u64, 2), pending[0].sequence);
    try testing.expectEqualStrings("Browser", pending[0].app_name);

    // Sequences must never be reused, even once every record is acknowledged.
    try box.acknowledge(2);
    try testing.expectEqual(@as(u64, 3), try box.append(testEvent(3000, "Terminal"), 1000));
}

test "an interrupted append is discarded and does not block later appends" {
    const allocator = testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.deinit(allocator);
    const path = try tmp.file(allocator, "outbox.log");
    defer allocator.free(path);

    {
        var box = try Outbox.open(allocator, path, .{});
        defer box.deinit();
        _ = try box.append(testEvent(1000, "Editor"), 1000);
        _ = try box.append(testEvent(2000, "Browser"), 1000);
    }

    // Simulate a crash partway through writing the trailing record.
    {
        const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
        defer file.close();
        const size = try file.getEndPos();
        try file.setEndPos(size - 4);
    }

    var box = try Outbox.open(allocator, path, .{});
    defer box.deinit();
    var batch: [8]outbox.Record = undefined;
    try testing.expectEqual(@as(usize, 1), box.pending(&batch).len);
    try testing.expectEqualStrings("Editor", box.pending(&batch)[0].app_name);

    // The interrupted record burned its sequence: reusing it would let the
    // backend treat different activity as an already-committed duplicate.
    try testing.expectEqual(@as(u64, 3), try box.append(testEvent(3000, "Terminal"), 1000));
    const recovered = box.pending(&batch);
    try testing.expectEqual(@as(usize, 2), recovered.len);
    try testing.expectEqualStrings("Terminal", recovered[1].app_name);
}

test "a corrupted record is rejected instead of being delivered" {
    const allocator = testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.deinit(allocator);
    const path = try tmp.file(allocator, "outbox.log");
    defer allocator.free(path);

    {
        var box = try Outbox.open(allocator, path, .{});
        defer box.deinit();
        _ = try box.append(testEvent(1000, "Editor"), 1000);
        _ = try box.append(testEvent(2000, "Browser"), 1000);
    }
    {
        const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
        defer file.close();
        const size = try file.getEndPos();
        try file.seekTo(size - 2);
        try file.writeAll("!!");
    }

    var box = try Outbox.open(allocator, path, .{});
    defer box.deinit();
    var batch: [8]outbox.Record = undefined;
    const pending = box.pending(&batch);
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqualStrings("Editor", pending[0].app_name);
}

test "a full outbox reports an error and keeps recorded activity" {
    const allocator = testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.deinit(allocator);
    const path = try tmp.file(allocator, "outbox.log");
    defer allocator.free(path);

    var box = try Outbox.open(allocator, path, .{ .max_bytes = outbox.header_len + 128 });
    defer box.deinit();
    _ = try box.append(testEvent(1000, "Editor"), 1000);

    var appended: usize = 1;
    while (box.append(testEvent(2000, "Browser"), 1000)) |_| {
        appended += 1;
        if (appended > 100) return error.OutboxNeverFilled;
    } else |err| try testing.expectEqual(outbox.Error.OutboxFull, err);

    var batch: [128]outbox.Record = undefined;
    try testing.expectEqual(appended, box.pending(&batch).len);

    // Acknowledging makes room again rather than leaving the client stuck.
    try box.acknowledge(@intCast(appended));
    _ = try box.append(testEvent(3000, "Terminal"), 1000);
}
