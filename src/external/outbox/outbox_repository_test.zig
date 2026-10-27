const std = @import("std");
const testing = std.testing;
const Event = @import("domain_event").Event;
const outbox = @import("outbox.zig");
const delivery = @import("delivery.zig");
const OutboxRepository = @import("outbox_repository.zig").OutboxRepository;

/// Backend stand-in: remembers the batches it was given and answers with the
/// sequence it "committed", exactly as the real ingestion endpoint does.
const FakeBackend = struct {
    allocator: std.mem.Allocator,
    bodies: std.ArrayListUnmanaged([]u8) = .{},
    acknowledge_through: u64 = 0,
    status: u16 = 200,
    retryable: bool = false,
    unreachable_until_call: usize = 0,
    calls: usize = 0,

    fn deinit(self: *FakeBackend) void {
        for (self.bodies.items) |body| self.allocator.free(body);
        self.bodies.deinit(self.allocator);
    }

    fn transport(self: *FakeBackend) delivery.Transport {
        return .{ .ptr = self, .send = send };
    }

    fn send(ptr: *anyopaque, body: []const u8) anyerror!delivery.Response {
        const self: *FakeBackend = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (self.calls <= self.unreachable_until_call) return error.ConnectionRefused;
        try self.bodies.append(self.allocator, try self.allocator.dupe(u8, body));
        // Commit everything offered, the way the real backend does on success.
        const highest = highestSequence(body);
        if (self.status == 200 and highest > self.acknowledge_through) {
            self.acknowledge_through = highest;
        }
        return .{
            .status = self.status,
            .retryable = self.retryable,
            .acknowledged_sequence = self.acknowledge_through,
        };
    }

    fn highestSequence(body: []const u8) u64 {
        var highest: u64 = 0;
        var rest = body;
        while (std.mem.indexOf(u8, rest, "\"sequence\":")) |at| {
            rest = rest[at + "\"sequence\":".len ..];
            var end: usize = 0;
            while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
            const value = std.fmt.parseInt(u64, rest[0..end], 10) catch 0;
            if (value > highest) highest = value;
        }
        return highest;
    }
};

const TempDir = struct {
    dir: testing.TmpDir,
    path: []u8,

    fn init(allocator: std.mem.Allocator) !TempDir {
        var dir = testing.tmpDir(.{});
        errdefer dir.cleanup();
        const path = try dir.dir.realpathAlloc(allocator, ".");
        return .{ .dir = dir, .path = path };
    }

    fn outboxPath(self: TempDir, allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.path, "outbox.log" });
    }

    fn deinit(self: *TempDir, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.dir.cleanup();
    }
};

const sample = Event{
    .timestamp_ms = 1_700_000_000_000,
    .app_name = "Ghostty",
    .window_title = "zig build test",
    .wifi_ssid = "office",
};

test "a saved interval is durable before it is delivered" {
    const allocator = testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.deinit(allocator);
    const path = try tmp.outboxPath(allocator);
    defer allocator.free(path);

    // A backend that never answers, so nothing can be acknowledged away.
    var backend = FakeBackend{ .allocator = allocator, .unreachable_until_call = 1000 };
    defer backend.deinit();

    var repo = try OutboxRepository.init(allocator, path, backend.transport(), .{});
    repo.save(sample, 5_000);
    repo.deinit();

    // Reopened from disk alone, the interval is still there.
    var reopened = try outbox.Outbox.open(allocator, path, .{});
    defer reopened.deinit();
    try testing.expectEqual(@as(usize, 1), reopened.pendingCount());
}

test "delivering hands the backend the saved interval and clears it" {
    const allocator = testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.deinit(allocator);
    const path = try tmp.outboxPath(allocator);
    defer allocator.free(path);

    var backend = FakeBackend{ .allocator = allocator };
    defer backend.deinit();

    var repo = try OutboxRepository.init(allocator, path, backend.transport(), .{});
    defer repo.deinit();

    repo.save(sample, 5_000);
    const outcome = try repo.deliverNow();

    try testing.expectEqual(delivery.Outcome.delivered, outcome);
    try testing.expectEqual(@as(usize, 0), repo.pendingCount());
    try testing.expectEqual(@as(usize, 1), backend.bodies.items.len);
    try testing.expect(std.mem.indexOf(u8, backend.bodies.items[0], "Ghostty") != null);
}

test "an unreachable backend keeps the interval and resends it later" {
    const allocator = testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.deinit(allocator);
    const path = try tmp.outboxPath(allocator);
    defer allocator.free(path);

    var backend = FakeBackend{ .allocator = allocator, .unreachable_until_call = 1 };
    defer backend.deinit();

    var repo = try OutboxRepository.init(allocator, path, backend.transport(), .{});
    defer repo.deinit();

    repo.save(sample, 5_000);

    try testing.expectEqual(delivery.Outcome.retry_later, try repo.deliverNow());
    try testing.expectEqual(@as(usize, 1), repo.pendingCount());

    try testing.expectEqual(delivery.Outcome.delivered, try repo.deliverNow());
    try testing.expectEqual(@as(usize, 0), repo.pendingCount());
}

test "replaying the same interval twice does not duplicate it" {
    const allocator = testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.deinit(allocator);
    const path = try tmp.outboxPath(allocator);
    defer allocator.free(path);

    var backend = FakeBackend{ .allocator = allocator };
    defer backend.deinit();

    var repo = try OutboxRepository.init(allocator, path, backend.transport(), .{});
    defer repo.deinit();

    repo.save(sample, 5_000);
    _ = try repo.deliverNow();
    // Nothing pending, so a second round trip sends nothing at all.
    try testing.expectEqual(delivery.Outcome.idle, try repo.deliverNow());
    try testing.expectEqual(@as(usize, 1), backend.bodies.items.len);
}

test "a full outbox surfaces a recording error instead of dropping activity" {
    const allocator = testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.deinit(allocator);
    const path = try tmp.outboxPath(allocator);
    defer allocator.free(path);

    var backend = FakeBackend{ .allocator = allocator };
    defer backend.deinit();

    var repo = try OutboxRepository.init(allocator, path, backend.transport(), .{
        .outbox = .{ .max_bytes = outbox.header_len + 16 },
    });
    defer repo.deinit();

    try testing.expect(repo.recordingError() == null);
    repo.save(sample, 5_000);

    try testing.expectEqual(outbox.Error.OutboxFull, repo.recordingError().?);
    try testing.expectEqual(@as(usize, 0), repo.pendingCount());
}

test "a later successful save clears the recording error" {
    const allocator = testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.deinit(allocator);
    const path = try tmp.outboxPath(allocator);
    defer allocator.free(path);

    var backend = FakeBackend{ .allocator = allocator };
    defer backend.deinit();

    var repo = try OutboxRepository.init(allocator, path, backend.transport(), .{});
    defer repo.deinit();

    var oversized = sample;
    const too_long = [_]u8{'x'} ** (outbox.max_text_len + 1);
    oversized.window_title = &too_long;
    repo.save(oversized, 1_000);
    try testing.expectEqual(outbox.Error.TextTooLong, repo.recordingError().?);

    repo.save(sample, 5_000);
    try testing.expect(repo.recordingError() == null);
    try testing.expectEqual(@as(usize, 1), repo.pendingCount());
}

test "stopping delivers whatever is still pending" {
    const allocator = testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.deinit(allocator);
    const path = try tmp.outboxPath(allocator);
    defer allocator.free(path);

    var backend = FakeBackend{ .allocator = allocator };
    defer backend.deinit();

    var repo = try OutboxRepository.init(allocator, path, backend.transport(), .{});
    repo.save(sample, 5_000);
    repo.deinit();

    try testing.expectEqual(@as(usize, 1), backend.bodies.items.len);

    var reopened = try outbox.Outbox.open(allocator, path, .{});
    defer reopened.deinit();
    try testing.expectEqual(@as(usize, 0), reopened.pendingCount());
}

test "the delivery loop drains saved intervals without an explicit call" {
    const allocator = testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.deinit(allocator);
    const path = try tmp.outboxPath(allocator);
    defer allocator.free(path);

    var backend = FakeBackend{ .allocator = allocator };
    defer backend.deinit();

    var repo = try OutboxRepository.init(allocator, path, backend.transport(), .{
        .delivery_interval_ms = 1,
    });
    defer repo.deinit();

    try repo.startDeliveryTimer();
    repo.save(sample, 5_000);

    var waited_ms: usize = 0;
    while (repo.pendingCount() > 0 and waited_ms < 2_000) : (waited_ms += 5) {
        std.posix.nanosleep(0, 5 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(usize, 0), repo.pendingCount());
}

test "saving from several threads records every interval exactly once" {
    const allocator = testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.deinit(allocator);
    const path = try tmp.outboxPath(allocator);
    defer allocator.free(path);

    var backend = FakeBackend{ .allocator = allocator };
    defer backend.deinit();

    var repo = try OutboxRepository.init(allocator, path, backend.transport(), .{});
    defer repo.deinit();

    const Saver = struct {
        fn go(r: *OutboxRepository) void {
            var i: usize = 0;
            while (i < 25) : (i += 1) r.save(sample, 1_000);
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Saver.go, .{&repo});
    for (threads) |thread| thread.join();

    try testing.expectEqual(@as(usize, 100), repo.pendingCount());
    try testing.expect(repo.recordingError() == null);
}
