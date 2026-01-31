const std = @import("std");
const Tracker = @import("tracker").Tracker;
const DuckDbRepository = @import("duckdb_repository").DuckDbRepository;

// Import functions from Swift bridge
extern fn check_accessibility() bool;
extern fn start_listening(cb: *const fn ([*c]const u8, [*c]const u8, i32) callconv(.c) void) void;

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
    const timestamp = getTimestampMs();

    std.debug.print("[Event] App: {s} | Title: {s}\n", .{ app, title });

    // Track the event
    if (global_tracker) |tracker| {
        tracker.onEvent(app, title, timestamp);
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

pub fn main() void {
    std.debug.print("=== Time Tracker ===\n\n", .{});

    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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
