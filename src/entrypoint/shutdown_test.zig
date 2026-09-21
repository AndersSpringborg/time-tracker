const std = @import("std");
const testing = std.testing;
const shutdown = @import("shutdown");

const CountingHook = struct {
    calls: usize = 0,

    fn run(ctx: *anyopaque) void {
        const self: *CountingHook = @ptrCast(@alignCast(ctx));
        self.calls += 1;
    }

    fn hook(self: *CountingHook) shutdown.Hook {
        return .{ .context = @ptrCast(self), .runFn = CountingHook.run };
    }
};

test "runOnce runs the hook the first time and reports that it ran" {
    var counter = CountingHook{};
    var coordinator = shutdown.Coordinator{};

    const ran = coordinator.runOnce(counter.hook());

    try testing.expect(ran);
    try testing.expectEqual(@as(usize, 1), counter.calls);
}

test "runOnce leaves the hook alone on every later call" {
    var counter = CountingHook{};
    var coordinator = shutdown.Coordinator{};

    _ = coordinator.runOnce(counter.hook());
    const second = coordinator.runOnce(counter.hook());
    const third = coordinator.runOnce(counter.hook());

    try testing.expect(!second);
    try testing.expect(!third);
    try testing.expectEqual(@as(usize, 1), counter.calls);
}

test "request marks the coordinator as requested" {
    var coordinator = shutdown.Coordinator{};

    try testing.expect(!coordinator.isRequested());
    coordinator.request();
    try testing.expect(coordinator.isRequested());
}

test "waitAndRun blocks until another thread requests shutdown, then runs the hook once" {
    var counter = CountingHook{};
    var coordinator = shutdown.Coordinator{ .poll_interval_ms = 1 };

    const requester = try std.Thread.spawn(.{}, struct {
        fn go(c: *shutdown.Coordinator) void {
            std.posix.nanosleep(0, 5 * std.time.ns_per_ms);
            c.request();
        }
    }.go, .{&coordinator});

    coordinator.waitAndRun(counter.hook());
    requester.join();

    try testing.expectEqual(@as(usize, 1), counter.calls);
}

test "waitAndRun returns immediately when shutdown was already requested" {
    var counter = CountingHook{};
    var coordinator = shutdown.Coordinator{ .poll_interval_ms = 1 };
    coordinator.request();

    coordinator.waitAndRun(counter.hook());

    try testing.expectEqual(@as(usize, 1), counter.calls);
}

test "installed handlers mark the global coordinator on SIGTERM" {
    shutdown.installHandlers();
    defer shutdown.global = .{};

    try testing.expect(!shutdown.global.isRequested());
    std.posix.raise(std.posix.SIG.TERM) catch unreachable;

    try testing.expect(shutdown.global.isRequested());
}

test "installed handlers mark the global coordinator on SIGINT" {
    shutdown.global = .{};
    shutdown.installHandlers();
    defer shutdown.global = .{};

    std.posix.raise(std.posix.SIG.INT) catch unreachable;

    try testing.expect(shutdown.global.isRequested());
}
