//! Time Tracker Daemon
//!
//! This is the daemon entry point that integrates with Swift for macOS event tracking.
//! For all CLI commands, use the `tt` binary instead.

const std = @import("std");
const Tracker = @import("tracker").Tracker;
const BufferedRepository = @import("buffered_repository").BufferedRepository;

// Import functions from Swift bridge
extern fn check_accessibility() bool;
extern fn start_listening(cb: *const fn ([*c]const u8, [*c]const u8, [*c]const u8, i32) callconv(.c) void) void;

// Global state (needed for C callback)
var global_tracker: ?*Tracker = null;
var global_repo: ?*BufferedRepository = null;

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
    return full_path[0 .. full_path.len - 1 :0];
}

fn printUsage() void {
    const usage =
        \\Usage: time_tracker <command>
        \\
        \\Commands:
        \\  daemon         Start the time tracking daemon
        \\
        \\For all other commands, use the 'tt' CLI tool:
        \\  tt summary     Show time spent per application
        \\  tt report      Show detailed report with window titles
        \\  tt import      Import customer hierarchy from JSON file
        \\  tt rules       Manage mapping rules
        \\  tt apply-rules Apply rules to unmapped events
        \\  tt review      Interactively review and map unmapped events
        \\  tt projects    Manage active project context
        \\  tt help        Show help
        \\
    ;
    std.debug.print("{s}", .{usage});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "daemon")) {
        runDaemon(allocator);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        std.debug.print("For CLI commands, use the 'tt' tool instead.\n\n", .{});
        printUsage();
    }
}

fn runDaemon(allocator: std.mem.Allocator) void {
    std.debug.print("=== Time Tracker Daemon ===\n\n", .{});

    const db_path = getDbPath(allocator) catch |err| {
        std.debug.print("Failed to determine database path: {}\n", .{err});
        return;
    };

    std.debug.print("Database: {s}\n", .{db_path});

    // Initialize buffered repository (opens DB only during flush)
    var repo = BufferedRepository.init(allocator, db_path);
    defer repo.deinit();
    global_repo = &repo;

    // Start the background flush timer (flushes to DB after 5s of inactivity)
    repo.startFlushTimer() catch |err| {
        std.debug.print("Failed to start flush timer: {}\n", .{err});
        return;
    };

    std.debug.print("Buffered repository initialized (flushes after 5s of inactivity).\n", .{});

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
