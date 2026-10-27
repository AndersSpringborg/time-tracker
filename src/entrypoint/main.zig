const std = @import("std");
const config = @import("config");

/// Keep stderr quiet in the daemon: suppress std.log.debug output, including
/// the per-operation tracing emitted by the flatbufferz Builder on every event.
pub const std_options: std.Options = .{
    .log_level = .info,
};
const shutdown = @import("shutdown");
const menu_state = @import("menu_state");
const status_client = @import("status_client");

const Tracker = @import("tracker").Tracker;
const outbox_repository = @import("outbox_repository");
const OutboxRepository = outbox_repository.OutboxRepository;
const SocketTransport = outbox_repository.SocketTransport;
const event_dto_mapper = @import("event_dto_mapper");

extern fn check_accessibility() bool;
extern fn start_listening(cb: *const fn ([*c]const u8, [*c]const u8, [*c]const u8, i32) callconv(.c) void) void;
extern fn add_work_wifi(pattern: [*c]const u8) void;
extern fn clear_work_wifis() void;
extern fn update_matched_info(project: [*c]const u8, activity: [*c]const u8) void;
extern fn clear_matched_info() void;
extern fn update_unmatched_count(count: i64) void;

const menu_refresh_interval_ms: u64 = 5_000;

var global_menu: menu_state.MenuState = .{};
var global_tracker: ?*Tracker = null;
var global_allocator: ?std.mem.Allocator = null;
var global_daemon_data_dir_buf: [640]u8 = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        std.process.exit(2);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "daemon")) {
        runDaemon(allocator);
        return;
    }

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
        return;
    }

    printMigratedCommandHelp(command);
    std.process.exit(2);
}

fn printUsage() void {
    const usage =
        \\Usage: tt <command>
        \\ 
        \\Worker command:
        \\  daemon         Start event collector + menubar worker (macOS)
        \\ 
        \\This Zig binary is now worker-only.
        \\For CLI/API/business workflows use the Go binary: ./tracker
        \\ 
        \\Examples:
        \\  tt daemon
        \\  ./tracker help
        \\  ./tracker rules apply-rules --dry-run --format json
        \\  ./tracker reports --range week --format json
        \\  ./tracker review groups --format json
        \\ 
    ;
    std.debug.print("{s}", .{usage});
}

fn printMigratedCommandHelp(command: []const u8) void {
    std.debug.print("Command '{s}' moved to Go CLI.\n", .{command});
    std.debug.print("Use './tracker help' for the full command list.\n\n", .{});

    if (std.mem.eql(u8, command, "summary") or std.mem.eql(u8, command, "report")) {
        std.debug.print("Migration: ./tracker reports --range today\n", .{});
    } else if (std.mem.eql(u8, command, "rules") or std.mem.eql(u8, command, "apply-rules")) {
        std.debug.print("Migration: ./tracker rules <subcommand>\n", .{});
    } else if (std.mem.eql(u8, command, "projects")) {
        std.debug.print("Migration: ./tracker projects <subcommand>\n", .{});
    } else if (std.mem.eql(u8, command, "config") or std.mem.eql(u8, command, "wifi")) {
        std.debug.print("Migration: ./tracker settings <list|get|set|unset>\n", .{});
    } else if (std.mem.eql(u8, command, "review")) {
        std.debug.print("Migration: ./tracker review <subcommand>\n", .{});
    } else {
        std.debug.print("Migration: ./tracker <command>\n", .{});
    }
}

fn getTimestampMs() i64 {
    const ts = std.posix.clock_gettime(.REALTIME) catch return 0;
    const sec_ms: i64 = ts.sec * 1000;
    const nsec_ms: i64 = @divFloor(ts.nsec, 1_000_000);
    return sec_ms + nsec_ms;
}

fn onEvent(
    c_app: [*c]const u8,
    c_title: [*c]const u8,
    c_wifi: [*c]const u8,
    error_code: i32,
) callconv(.c) void {
    if (error_code == 1) {
        std.debug.print(
            \\
            \\ERROR: Accessibility permission required!
            \\
            \\Please grant access in:
            \\  System Settings -> Privacy & Security -> Accessibility
            \\
            \\Add the running binary (usually ~/.local/bin/tt-worker for launchd installs).
            \\Keep the worker running; tracking will start automatically after permission is granted.
            \\
        , .{});
        return;
    }

    const app = std.mem.span(c_app);
    const title = std.mem.span(c_title);
    const wifi = std.mem.span(c_wifi);
    const timestamp = getTimestampMs();

    const allocator = global_allocator orelse return;

    const dto_payload = event_dto_mapper.EventDto{
        .timestamp_ms = timestamp,
        .app_name = app,
        .window_title = title,
        .wifi_ssid = wifi,
        .duration_ms = 0,
        .has_project_id = false,
        .project_id = 0,
        .has_activity_id = false,
        .activity_id = 0,
        .manually_mapped = false,
    };

    const encoded = event_dto_mapper.encode(allocator, dto_payload) catch |err| {
        std.debug.print("Failed to encode event dto: {}\n", .{err});
        return;
    };
    defer allocator.free(encoded);

    const decoded = event_dto_mapper.decode(encoded) catch |err| {
        std.debug.print("Failed to decode event dto: {}\n", .{err});
        return;
    };
    const event = event_dto_mapper.toDomain(decoded);

    std.log.debug("[Event] App: {s} | Title: {s} | WiFi: {s}", .{ event.app_name, event.window_title, event.wifi_ssid });

    // Remember the window for the menu refresh. This is the AppKit main
    // thread, so it copies and returns; the backend is asked on another thread.
    global_menu.setWindow(event.app_name, event.window_title);

    if (global_tracker) |tracker| {
        tracker.onEventWithWifi(event.app_name, event.window_title, event.wifi_ssid, event.timestamp_ms);
    }
}

fn getDaemonDataDir() ![]const u8 {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const xdg_data = std.posix.getenv("XDG_DATA_HOME");

    const dir_path = if (xdg_data) |data_dir|
        std.fmt.bufPrint(&global_daemon_data_dir_buf, "{s}/time-tracker", .{data_dir}) catch return error.PathTooLong
    else
        std.fmt.bufPrint(&global_daemon_data_dir_buf, "{s}/.local/share/time-tracker", .{home}) catch return error.PathTooLong;

    std.fs.makeDirAbsolute(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("Warning: Could not create data directory: {s}\n", .{dir_path});
        }
    };
    return dir_path;
}

fn runDaemon(allocator: std.mem.Allocator) void {
    std.debug.print("=== Time Tracker Daemon ===\n\n", .{});

    var cfg = config.load(allocator) catch |err| {
        std.debug.print("Warning: Failed to load config: {}. Using defaults.\n", .{err});
        runDaemonWithDefaults(allocator);
        return;
    };
    defer cfg.deinit(allocator);

    if (cfg.work_wifis.len > 0) {
        std.debug.print("Work WiFi patterns: ", .{});
        for (cfg.work_wifis, 0..) |pattern, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{pattern});

            var pattern_buf: [128]u8 = undefined;
            if (pattern.len < pattern_buf.len) {
                @memcpy(pattern_buf[0..pattern.len], pattern);
                pattern_buf[pattern.len] = 0;
                add_work_wifi(&pattern_buf);
            }
        }
        std.debug.print("\n", .{});
    } else {
        std.debug.print("Work WiFi: (all networks)\n", .{});
        clear_work_wifis();
    }

    runDaemonCore(allocator);
}

fn runDaemonWithDefaults(allocator: std.mem.Allocator) void {
    std.debug.print("Work WiFi: (all networks)\n", .{});
    clear_work_wifis();
    runDaemonCore(allocator);
}

/// Refreshes the menubar from the backend on its own thread, so opening the
/// menu reads memory rather than waiting on IPC. A failed refresh leaves the
/// last snapshot in the menu instead of blanking it.
const MenuRefresher = struct {
    client: status_client.StatusClient,
    interval_ms: u64,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const tick_ms: u64 = 250;

    fn loop(self: *MenuRefresher) void {
        var waited_ms: u64 = 0;
        while (!self.should_stop.load(.acquire)) {
            std.posix.nanosleep(0, tick_ms * std.time.ns_per_ms);
            waited_ms += tick_ms;
            if (waited_ms < self.interval_ms) continue;
            waited_ms = 0;
            self.refreshOnce();
        }
    }

    fn refreshOnce(self: *MenuRefresher) void {
        var window_text: menu_state.WindowText = undefined;
        const window = global_menu.window(&window_text);

        const snapshot = self.client.fetch(window) catch {
            global_menu.recordFailure();
            return;
        };
        global_menu.recordSnapshot(snapshot);
        renderSnapshot(snapshot);
    }
};

/// Push the snapshot into the AppKit menu. Both names are copied into
/// null-terminated buffers because Swift reads them as C strings.
fn renderSnapshot(snapshot: status_client.Snapshot) void {
    update_unmatched_count(snapshot.unmatched_count);

    if (!snapshot.matched) {
        clear_matched_info();
        return;
    }
    var project_buf: [status_client.max_name_len + 1]u8 = undefined;
    var activity_buf: [status_client.max_name_len + 1]u8 = undefined;
    const project = snapshot.project();
    const activity = snapshot.activity();
    @memcpy(project_buf[0..project.len], project);
    project_buf[project.len] = 0;
    @memcpy(activity_buf[0..activity.len], activity);
    activity_buf[activity.len] = 0;
    update_matched_info(&project_buf, &activity_buf);
}

/// Flushes the trailing interval and the buffered events, in that order, so a
/// stop does not discard the pending window plus everything still buffered.
const DaemonStopper = struct {
    tracker: *Tracker,
    repo: *OutboxRepository,

    fn stop(ctx: *anyopaque) void {
        const self: *DaemonStopper = @ptrCast(@alignCast(ctx));
        self.tracker.deinit();
        self.repo.deinit();
    }

    fn hook(self: *DaemonStopper) shutdown.Hook {
        return .{ .context = @ptrCast(self), .runFn = DaemonStopper.stop };
    }
};

fn watchForShutdown(stopper: *DaemonStopper) void {
    shutdown.global.waitAndRun(stopper.hook());
    std.process.exit(0);
}

fn runDaemonCore(allocator: std.mem.Allocator) void {
    const data_dir = getDaemonDataDir() catch |err| {
        std.debug.print("Failed to determine data directory: {}\n", .{err});
        return;
    };
    global_allocator = allocator;
    defer global_allocator = null;

    var outbox_path_buf: [640]u8 = undefined;
    const outbox_path = std.fmt.bufPrint(&outbox_path_buf, "{s}/outbox.log", .{data_dir}) catch {
        std.debug.print("Data directory path is too long: {s}\n", .{data_dir});
        return;
    };
    var socket_path_buf: [640]u8 = undefined;
    const socket_path = std.fmt.bufPrint(&socket_path_buf, "{s}/ipc.sock", .{data_dir}) catch {
        std.debug.print("Data directory path is too long: {s}\n", .{data_dir});
        return;
    };

    std.debug.print("Outbox:  {s}\n", .{outbox_path});
    std.debug.print("Backend: {s}\n", .{socket_path});

    var transport = SocketTransport{ .path = socket_path };
    var repo = OutboxRepository.init(allocator, outbox_path, transport.transport(), .{}) catch |err| {
        std.debug.print("Failed to open the outbox: {}\n", .{err});
        return;
    };

    repo.startDeliveryTimer() catch |err| {
        std.debug.print("Failed to start delivery timer: {}\n", .{err});
        repo.deinit();
        return;
    };

    std.debug.print("Outbox initialized (delivers to the backend every 5 seconds).\n", .{});

    var tracker = Tracker.init(&repo);
    global_tracker = &tracker;
    defer global_tracker = null;

    tracker.startSampleTimer() catch |err| {
        std.debug.print("Failed to start sample timer: {}\n", .{err});
        repo.deinit();
        return;
    };

    // AppKit's terminate calls exit() and launchd stops us with SIGTERM, so
    // start_listening never returns and plain defers never run. Flush through
    // the shutdown coordinator instead, from whichever path reaches it first.
    var stopper = DaemonStopper{ .tracker = &tracker, .repo = &repo };
    defer _ = shutdown.global.runOnce(stopper.hook());

    shutdown.installHandlers();
    const watcher = std.Thread.spawn(.{}, watchForShutdown, .{&stopper}) catch |err| {
        std.debug.print("Failed to start shutdown watcher: {}\n", .{err});
        return;
    };
    watcher.detach();

    var refresher = MenuRefresher{
        .client = .{ .path = socket_path },
        .interval_ms = menu_refresh_interval_ms,
    };
    const refresher_thread = std.Thread.spawn(.{}, MenuRefresher.loop, .{&refresher}) catch |err| {
        std.debug.print("Failed to start menu refresher: {}\n", .{err});
        return;
    };
    refresher_thread.detach();

    std.debug.print("Window sampling initialized (logs the dominant window per 5s).\n", .{});
    std.debug.print("Menubar refreshes from the backend every 5 seconds.\n", .{});

    if (!check_accessibility()) {
        std.debug.print("\nWarning: Accessibility not yet granted. Will report error on start.\n", .{});
    }

    std.debug.print("\nStarting event listener... (switch windows to see events)\n", .{});
    std.debug.print("Press Ctrl+C to exit.\n\n", .{});

    start_listening(&onEvent);
}
