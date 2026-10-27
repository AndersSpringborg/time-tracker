const std = @import("std");
const Event = @import("domain_event").Event;
const outbox = @import("outbox.zig");
const delivery = @import("delivery.zig");

const testing = std.testing;

/// Scripted stand-in for the backend socket: the transport is an architectural
/// boundary, so failures are injected here rather than in the outbox.
const FakeBackend = struct {
    allocator: std.mem.Allocator,
    responses: []const Step,
    call: usize = 0,
    bodies: std.ArrayListUnmanaged([]u8) = .{},

    const Step = union(enum) {
        accepted: u64,
        rejected: delivery.Response,
        unreachable_backend: void,
    };

    fn deinit(self: *FakeBackend) void {
        for (self.bodies.items) |body| self.allocator.free(body);
        self.bodies.deinit(self.allocator);
    }

    fn transport(self: *FakeBackend) delivery.Transport {
        return .{ .ptr = self, .send = send };
    }

    fn send(ptr: *anyopaque, body: []const u8) anyerror!delivery.Response {
        const self: *FakeBackend = @ptrCast(@alignCast(ptr));
        try self.bodies.append(self.allocator, try self.allocator.dupe(u8, body));
        const step = self.responses[@min(self.call, self.responses.len - 1)];
        self.call += 1;
        return switch (step) {
            .accepted => |sequence| .{ .status = 200, .retryable = false, .acknowledged_sequence = sequence },
            .rejected => |response| response,
            .unreachable_backend => error.ConnectionRefused,
        };
    }

    fn lastBody(self: *FakeBackend) []const u8 {
        return self.bodies.items[self.bodies.items.len - 1];
    }
};

const Batch = struct {
    producer_id: []const u8,
    intervals: []const Interval,

    const Interval = struct {
        sequence: u64,
        timestamp_ms: i64,
        duration_ms: i64,
        app_name: []const u8,
        window_title: []const u8,
        wifi_ssid: []const u8,
    };
};

fn parseBatch(allocator: std.mem.Allocator, body: []const u8) !std.json.Parsed(Batch) {
    return std.json.parseFromSlice(Batch, allocator, body, .{});
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    path: []u8,
    box: outbox.Outbox,

    fn init(allocator: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try tmp.dir.realpathAlloc(allocator, ".");
        defer allocator.free(dir);
        const path = try std.fs.path.join(allocator, &.{ dir, "outbox.log" });
        errdefer allocator.free(path);
        return Fixture{ .tmp = tmp, .path = path, .box = try outbox.Outbox.open(allocator, path, .{}) };
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.box.deinit();
        allocator.free(self.path);
        self.tmp.cleanup();
    }
};

fn event(timestamp_ms: i64, app: []const u8) Event {
    return Event{ .timestamp_ms = timestamp_ms, .app_name = app, .window_title = "window", .wifi_ssid = "Office" };
}

test "a committed batch is acknowledged and removed from the outbox" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);
    _ = try fixture.box.append(event(1000, "Editor"), 5000);
    _ = try fixture.box.append(event(6000, "Browser"), 3000);

    var backend = FakeBackend{ .allocator = allocator, .responses = &.{.{ .accepted = 2 }} };
    defer backend.deinit();
    var sender = delivery.Delivery{ .outbox = &fixture.box, .transport = backend.transport() };

    try testing.expectEqual(delivery.Outcome.delivered, try sender.deliverPending());
    try testing.expectEqual(@as(usize, 0), fixture.box.pendingCount());

    const parsed = try parseBatch(allocator, backend.lastBody());
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.intervals.len);
    try testing.expectEqual(@as(usize, outbox.producer_id_len * 2), parsed.value.producer_id.len);
    try testing.expectEqual(@as(u64, 1), parsed.value.intervals[0].sequence);
    try testing.expectEqual(@as(i64, 5000), parsed.value.intervals[0].duration_ms);
    try testing.expectEqualStrings("Editor", parsed.value.intervals[0].app_name);
    try testing.expectEqualStrings("Browser", parsed.value.intervals[1].app_name);
}

test "an empty outbox sends nothing" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);

    var backend = FakeBackend{ .allocator = allocator, .responses = &.{.{ .accepted = 0 }} };
    defer backend.deinit();
    var sender = delivery.Delivery{ .outbox = &fixture.box, .transport = backend.transport() };

    try testing.expectEqual(delivery.Outcome.idle, try sender.deliverPending());
    try testing.expectEqual(@as(usize, 0), backend.call);
}

test "an unreachable backend keeps activity and backs off before retrying" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);
    _ = try fixture.box.append(event(1000, "Editor"), 5000);

    var backend = FakeBackend{
        .allocator = allocator,
        .responses = &.{ .unreachable_backend, .unreachable_backend, .{ .accepted = 1 } },
    };
    defer backend.deinit();
    var sender = delivery.Delivery{ .outbox = &fixture.box, .transport = backend.transport() };

    try testing.expectEqual(delivery.Outcome.retry_later, try sender.deliverPending());
    try testing.expectEqual(@as(usize, 1), fixture.box.pendingCount());
    const first_delay = sender.retryDelayMs();
    try testing.expect(first_delay > 0);

    try testing.expectEqual(delivery.Outcome.retry_later, try sender.deliverPending());
    try testing.expect(sender.retryDelayMs() > first_delay);

    try testing.expectEqual(delivery.Outcome.delivered, try sender.deliverPending());
    try testing.expectEqual(@as(usize, 0), fixture.box.pendingCount());
    try testing.expectEqual(@as(u64, 0), sender.retryDelayMs());

    // The same sequence is resent until it is acknowledged.
    const parsed = try parseBatch(allocator, backend.lastBody());
    defer parsed.deinit();
    try testing.expectEqual(@as(u64, 1), parsed.value.intervals[0].sequence);
}

test "a retryable rejection keeps activity for the next attempt" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);
    _ = try fixture.box.append(event(1000, "Editor"), 5000);

    var backend = FakeBackend{
        .allocator = allocator,
        .responses = &.{.{ .rejected = .{ .status = 503, .retryable = true, .acknowledged_sequence = 0 } }},
    };
    defer backend.deinit();
    var sender = delivery.Delivery{ .outbox = &fixture.box, .transport = backend.transport() };

    try testing.expectEqual(delivery.Outcome.retry_later, try sender.deliverPending());
    try testing.expectEqual(@as(usize, 1), fixture.box.pendingCount());
}

test "a permanent rejection is reported without discarding activity" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);
    _ = try fixture.box.append(event(1000, "Editor"), 5000);

    var backend = FakeBackend{
        .allocator = allocator,
        .responses = &.{.{ .rejected = .{ .status = 400, .retryable = false, .acknowledged_sequence = 0 } }},
    };
    defer backend.deinit();
    var sender = delivery.Delivery{ .outbox = &fixture.box, .transport = backend.transport() };

    try testing.expectEqual(delivery.Outcome.rejected, try sender.deliverPending());
    try testing.expectEqual(@as(usize, 1), fixture.box.pendingCount());
}

test "only the acknowledged prefix of a batch is removed" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);
    _ = try fixture.box.append(event(1000, "Editor"), 1000);
    _ = try fixture.box.append(event(2000, "Browser"), 1000);
    _ = try fixture.box.append(event(3000, "Terminal"), 1000);

    var backend = FakeBackend{ .allocator = allocator, .responses = &.{.{ .accepted = 2 }} };
    defer backend.deinit();
    var sender = delivery.Delivery{ .outbox = &fixture.box, .transport = backend.transport() };

    try testing.expectEqual(delivery.Outcome.delivered, try sender.deliverPending());
    var batch: [4]outbox.Record = undefined;
    const pending = fixture.box.pending(&batch);
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqual(@as(u64, 3), pending[0].sequence);
}

test "batches are bounded so a long outage is drained in steps" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);
    for (0..5) |i| _ = try fixture.box.append(event(@intCast(i * 1000), "Editor"), 1000);

    var backend = FakeBackend{ .allocator = allocator, .responses = &.{ .{ .accepted = 2 }, .{ .accepted = 4 }, .{ .accepted = 5 } } };
    defer backend.deinit();
    var sender = delivery.Delivery{ .outbox = &fixture.box, .transport = backend.transport(), .max_batch = 2 };

    const first = try parseBatchAfter(allocator, &sender, &backend);
    defer first.deinit();
    try testing.expectEqual(@as(usize, 2), first.value.intervals.len);
    try testing.expectEqual(@as(usize, 3), fixture.box.pendingCount());

    _ = try sender.deliverPending();
    _ = try sender.deliverPending();
    try testing.expectEqual(@as(usize, 0), fixture.box.pendingCount());
}

fn parseBatchAfter(
    allocator: std.mem.Allocator,
    sender: *delivery.Delivery,
    backend: *FakeBackend,
) !std.json.Parsed(Batch) {
    _ = try sender.deliverPending();
    return parseBatch(allocator, backend.lastBody());
}

test "window titles with quotes and newlines survive delivery" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);
    _ = try fixture.box.append(Event{
        .timestamp_ms = 1000,
        .app_name = "Editor",
        .window_title = "say \"hi\"\n\tand quit\\",
        .wifi_ssid = "Office",
    }, 1000);

    var backend = FakeBackend{ .allocator = allocator, .responses = &.{.{ .accepted = 1 }} };
    defer backend.deinit();
    var sender = delivery.Delivery{ .outbox = &fixture.box, .transport = backend.transport() };
    try testing.expectEqual(delivery.Outcome.delivered, try sender.deliverPending());

    const parsed = try parseBatch(allocator, backend.lastBody());
    defer parsed.deinit();
    try testing.expectEqualStrings("say \"hi\"\n\tand quit\\", parsed.value.intervals[0].window_title);
}

test "intervals outside the ingestion bounds are clamped so they cannot block delivery" {
    const allocator = testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);
    // A laptop asleep for 34 hours, then a wall-clock step backwards.
    _ = try fixture.box.append(event(1000, "Finder"), 34 * std.time.ms_per_hour);
    _ = try fixture.box.append(event(2000, "Browser"), -44);
    _ = try fixture.box.append(event(3000, "Editor"), 5000);

    var backend = FakeBackend{ .allocator = allocator, .responses = &.{.{ .accepted = 3 }} };
    defer backend.deinit();
    var sender = delivery.Delivery{ .outbox = &fixture.box, .transport = backend.transport() };
    try testing.expectEqual(delivery.Outcome.delivered, try sender.deliverPending());

    const parsed = try parseBatch(allocator, backend.lastBody());
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, std.time.ms_per_day), parsed.value.intervals[0].duration_ms);
    try testing.expectEqual(@as(i64, 1), parsed.value.intervals[1].duration_ms);
    try testing.expectEqual(@as(i64, 5000), parsed.value.intervals[2].duration_ms);
}
