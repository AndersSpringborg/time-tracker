const std = @import("std");
const Tracker = @import("tracker").Tracker;
const DuckDbRepository = @import("duckdb_repository").DuckDbRepository;
const query = @import("query");

// Import functions from Swift bridge (only used in daemon mode)
extern fn check_accessibility() bool;
extern fn start_listening(cb: *const fn ([*c]const u8, [*c]const u8, [*c]const u8, i32) callconv(.c) void) void;

// Global state (needed for C callback)
var global_tracker: ?*Tracker = null;
var global_repo: ?*DuckDbRepository = null;

fn getTimestampMs() i64 {
    const ts = std.posix.clock_gettime(.REALTIME) catch return 0;
    const sec_ms: i64 = ts.sec * 1000;
    const nsec_ms: i64 = @divFloor(ts.nsec, 1_000_000);
    return sec_ms + nsec_ms;
}

// Callback that Swift calls on each event
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
            \\  System Settings → Privacy & Security → Accessibility
            \\
            \\Add your Terminal app (or the binary) and restart.
            \\
        , .{});
        return;
    }

    const app = std.mem.span(c_app);
    const title = std.mem.span(c_title);
    const wifi = std.mem.span(c_wifi);
    const timestamp = getTimestampMs();

    std.debug.print("[Event] App: {s} | Title: {s} | WiFi: {s}\n", .{ app, title, wifi });

    // Track the event
    if (global_tracker) |tracker| {
        tracker.onEventWithWifi(app, title, wifi, timestamp);
    }
}

fn getDbPath(allocator: std.mem.Allocator) ![:0]const u8 {
    // Use XDG_DATA_HOME or default to ~/.local/share
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const xdg_data = std.posix.getenv("XDG_DATA_HOME");

    var path_buf: [512]u8 = undefined;
    var path_len: usize = 0;

    if (xdg_data) |data_dir| {
        path_len = (std.fmt.bufPrint(&path_buf, "{s}/time-tracker", .{data_dir}) catch return error.PathTooLong).len;
    } else {
        path_len = (std.fmt.bufPrint(&path_buf, "{s}/.local/share/time-tracker", .{home}) catch return error.PathTooLong).len;
    }

    // Create directory if it doesn't exist
    const dir_path = path_buf[0..path_len];
    std.fs.makeDirAbsolute(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("Warning: Could not create data directory: {s}\n", .{dir_path});
        }
    };

    // Append database filename
    const full_path = std.fmt.allocPrint(allocator, "{s}/tracker.db\x00", .{dir_path}) catch return error.OutOfMemory;
    // Return as null-terminated slice
    return full_path[0 .. full_path.len - 1 :0];
}

fn printUsage() void {
    const usage =
        \\Usage: time_tracker <command> [options]
        \\
        \\Commands:
        \\  daemon      Start the time tracking daemon
        \\  summary     Show time spent per application
        \\  report      Show detailed report with window titles
        \\
        \\Options for summary/report:
        \\  --today     Show only today's data (default)
        \\  --week      Show last 7 days
        \\  --all       Show all time
        \\
        \\Examples:
        \\  time_tracker daemon
        \\  time_tracker summary --today
        \\  time_tracker report --week
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn runDaemon(allocator: std.mem.Allocator) void {
    std.debug.print("=== Time Tracker Daemon ===\n\n", .{});

    // Get database path
    const db_path = getDbPath(allocator) catch |err| {
        std.debug.print("Failed to determine database path: {}\n", .{err});
        return;
    };
    defer allocator.free(db_path);

    std.debug.print("Database: {s}\n", .{db_path});

    // Initialize DuckDB repository
    var repo = DuckDbRepository.init(db_path.ptr) catch |err| {
        std.debug.print("Failed to initialize database: {}\n", .{err});
        return;
    };
    defer repo.deinit();
    global_repo = &repo;

    std.debug.print("Database initialized successfully.\n", .{});

    // Initialize tracker with repository
    var tracker = Tracker.init(&repo);
    global_tracker = &tracker;

    // Check accessibility
    if (!check_accessibility()) {
        std.debug.print("\nWarning: Accessibility not yet granted. Will report error on start.\n", .{});
    }

    std.debug.print("\nStarting event listener... (switch windows to see events)\n", .{});
    std.debug.print("Press Ctrl+C to exit.\n\n", .{});

    // Hand control to Swift's NSRunLoop (blocks forever)
    start_listening(&onEvent);
}

fn runSummary(allocator: std.mem.Allocator, range: query.TimeRange) void {
    const db_path = getDbPath(allocator) catch |err| {
        std.debug.print("Failed to determine database path: {}\n", .{err});
        return;
    };
    defer allocator.free(db_path);

    var runner = query.QueryRunner.init(allocator, db_path.ptr) catch |err| {
        std.debug.print("Failed to open database: {}\n", .{err});
        return;
    };
    defer runner.deinit();

    const range_label = switch (range) {
        .today => "Today",
        .week => "Last 7 Days",
        .all => "All Time",
    };

    std.debug.print("\n=== Time Summary ({s}) ===\n\n", .{range_label});

    // Get total time
    const total_ms = runner.getTotalTrackedTime(range) catch 0;
    var total_buf: [32]u8 = undefined;
    std.debug.print("Total tracked: {s}\n\n", .{query.formatDuration(total_ms, &total_buf)});

    // Get per-app summary
    const summaries = runner.getAppSummary(range) catch |err| {
        std.debug.print("Failed to query: {}\n", .{err});
        return;
    };
    defer allocator.free(summaries);

    if (summaries.len == 0) {
        std.debug.print("No data recorded yet.\n", .{});
        return;
    }

    std.debug.print("{s:<30} {s:>12}\n", .{ "Application", "Time" });
    std.debug.print("{s:-<30} {s:->12}\n", .{ "", "" });

    for (summaries) |summary| {
        var dur_buf: [32]u8 = undefined;
        const duration = query.formatDuration(summary.total_ms, &dur_buf);
        std.debug.print("{s:<30} {s:>12}\n", .{ summary.app_name, duration });
    }

    std.debug.print("\n", .{});
}

fn runReport(allocator: std.mem.Allocator, range: query.TimeRange) void {
    const db_path = getDbPath(allocator) catch |err| {
        std.debug.print("Failed to determine database path: {}\n", .{err});
        return;
    };
    defer allocator.free(db_path);

    var runner = query.QueryRunner.init(allocator, db_path.ptr) catch |err| {
        std.debug.print("Failed to open database: {}\n", .{err});
        return;
    };
    defer runner.deinit();

    const range_label = switch (range) {
        .today => "Today",
        .week => "Last 7 Days",
        .all => "All Time",
    };

    std.debug.print("\n=== Detailed Report ({s}) ===\n\n", .{range_label});

    // Get total time
    const total_ms = runner.getTotalTrackedTime(range) catch 0;
    var total_buf: [32]u8 = undefined;
    std.debug.print("Total tracked: {s}\n", .{query.formatDuration(total_ms, &total_buf)});

    // Get per-app summary
    const summaries = runner.getAppSummary(range) catch |err| {
        std.debug.print("Failed to query: {}\n", .{err});
        return;
    };
    defer allocator.free(summaries);

    if (summaries.len == 0) {
        std.debug.print("No data recorded yet.\n", .{});
        return;
    }

    for (summaries) |summary| {
        var dur_buf: [32]u8 = undefined;
        const duration = query.formatDuration(summary.total_ms, &dur_buf);
        std.debug.print("\n{s} ({s})\n", .{ summary.app_name, duration });
        std.debug.print("{s:-<50}\n", .{""});

        // Get title details for this app
        const details = runner.getTitleDetails(summary.app_name, range) catch continue;
        defer allocator.free(details);

        for (details) |detail| {
            var detail_buf: [32]u8 = undefined;
            const detail_dur = query.formatDuration(detail.total_ms, &detail_buf);

            // Truncate long titles
            if (detail.window_title.len > 44) {
                var title_display: [47]u8 = undefined;
                @memcpy(title_display[0..44], detail.window_title[0..44]);
                @memcpy(title_display[44..47], "...");
                std.debug.print("  {s:<45} {s:>12}\n", .{ &title_display, detail_dur });
            } else {
                std.debug.print("  {s:<45} {s:>12}\n", .{ detail.window_title, detail_dur });
            }
        }
    }

    std.debug.print("\n", .{});
}

fn parseTimeRange(args: []const [:0]const u8) query.TimeRange {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--week")) return .week;
        if (std.mem.eql(u8, arg, "--all")) return .all;
        if (std.mem.eql(u8, arg, "--today")) return .today;
    }
    return .today; // default
}

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = std.process.argsAlloc(allocator) catch {
        std.debug.print("Failed to get arguments\n", .{});
        return;
    };
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "daemon")) {
        runDaemon(allocator);
    } else if (std.mem.eql(u8, command, "summary")) {
        const range = parseTimeRange(args[2..]);
        runSummary(allocator, range);
    } else if (std.mem.eql(u8, command, "report")) {
        const range = parseTimeRange(args[2..]);
        runReport(allocator, range);
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{command});
        printUsage();
    }
}
