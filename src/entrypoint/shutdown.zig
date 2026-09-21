const std = @import("std");

/// Work to run once, when the process is asked to stop.
pub const Hook = struct {
    context: *anyopaque,
    runFn: *const fn (*anyopaque) void,

    pub fn run(self: Hook) void {
        self.runFn(self.context);
    }
};

/// Coordinates one orderly shutdown.
///
/// A signal handler may only call `request`, which does nothing but flip an
/// atomic flag and is therefore async-signal-safe. The flushing itself — which
/// allocates, takes locks and talks to storage — happens on a normal thread
/// parked in `waitAndRun`.
pub const Coordinator = struct {
    requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ran: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    poll_interval_ms: u64 = 50,

    const Self = @This();

    /// Async-signal-safe: this is all a signal handler may do.
    pub fn request(self: *Self) void {
        self.requested.store(true, .release);
    }

    pub fn isRequested(self: *Self) bool {
        return self.requested.load(.acquire);
    }

    /// Run the hook if no one has run it yet. Returns whether this call ran it.
    pub fn runOnce(self: *Self, hook: Hook) bool {
        if (self.ran.swap(true, .acq_rel)) return false;
        hook.run();
        return true;
    }

    /// Park until shutdown is requested, then run the hook exactly once.
    pub fn waitAndRun(self: *Self, hook: Hook) void {
        while (!self.isRequested()) {
            std.posix.nanosleep(0, self.poll_interval_ms * std.time.ns_per_ms);
        }
        _ = self.runOnce(hook);
    }
};

/// The coordinator the installed signal handlers talk to.
pub var global: Coordinator = .{};

fn onSignal(_: i32) callconv(.c) void {
    global.request();
}

/// Route SIGTERM and SIGINT to `global`. launchd stops the worker with
/// SIGTERM and a terminal stops it with SIGINT; both must flush rather than
/// kill the process where it stands.
pub fn installHandlers() void {
    var action = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
}
