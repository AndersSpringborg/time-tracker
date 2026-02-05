//! Time Tracker Daemon
//!
//! This is the daemon entry point that integrates with Swift for macOS event tracking.
//! For all CLI commands, use the `tt` binary instead.

const std = @import("std");
const Tracker = @import("tracker").Tracker;
const BufferedRepository = @import("buffered_repository").BufferedRepository;
const config_mod = @import("config");
const domain_rule = @import("domain_rule");
const DuckDbRuleRepository = @import("duckdb_rule_repository").DuckDbRuleRepository;
const DuckDbHierarchyRepository = @import("duckdb_hierarchy_repository").DuckDbHierarchyRepository;
const DuckDbEventRepository = @import("duckdb_event_repository").DuckDbEventRepository;
const migrations = @import("migrations");
const c = migrations.c;

// Import functions from Swift bridge
extern fn check_accessibility() bool;
extern fn start_listening(cb: *const fn ([*c]const u8, [*c]const u8, [*c]const u8, i32) callconv(.c) void) void;
extern fn set_tracking_wifi(ssid: [*c]const u8) void;
extern fn clear_tracking_wifi() void;
extern fn update_matched_info(project: [*c]const u8, activity: [*c]const u8) void;
extern fn clear_matched_info() void;
extern fn update_unmatched_count(count: i64) void;

// Global state (needed for C callback)
var global_tracker: ?*Tracker = null;
var global_repo: ?*BufferedRepository = null;
var global_allocator: ?std.mem.Allocator = null;
var global_db_path: ?[:0]const u8 = null;

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

    // Try to match rules and update menubar
    matchAndUpdateMenubar(app, title);
}

/// Match the current event against rules and update the menubar with project/activity info
fn matchAndUpdateMenubar(app: []const u8, title: []const u8) void {
    const allocator = global_allocator orelse return;
    const db_path = global_db_path orelse return;

    // Open a temporary database connection for the query
    var db: c.duckdb_database = undefined;
    var conn: c.duckdb_connection = undefined;

    if (c.duckdb_open(db_path.ptr, &db) == c.DuckDBError) {
        return;
    }
    defer c.duckdb_close(&db);

    if (c.duckdb_connect(db, &conn) == c.DuckDBError) {
        return;
    }
    defer c.duckdb_disconnect(&conn);

    // Create rule repository and look for a match
    var rule_repo = DuckDbRuleRepository.init(conn, allocator);
    const match_result = rule_repo.findMatch(app, title) catch {
        clear_matched_info();
        return;
    };

    if (match_result) |match| {
        // Get project and activity names
        var hierarchy_repo = DuckDbHierarchyRepository.init(conn, allocator);
        const names = hierarchy_repo.getProjectAndActivityForKind(match.kind_id) catch {
            clear_matched_info();
            return;
        };
        defer {
            allocator.free(@constCast(names.project));
            allocator.free(@constCast(names.activity));
        }

        // Convert to null-terminated strings for C interop
        var project_buf: [256]u8 = undefined;
        var activity_buf: [256]u8 = undefined;

        if (names.project.len < project_buf.len and names.activity.len < activity_buf.len) {
            @memcpy(project_buf[0..names.project.len], names.project);
            project_buf[names.project.len] = 0;

            @memcpy(activity_buf[0..names.activity.len], names.activity);
            activity_buf[names.activity.len] = 0;

            update_matched_info(&project_buf, &activity_buf);
        }
    } else {
        clear_matched_info();
    }

    // Update unmatched event count in menubar
    updateUnmatchedCount(conn, allocator);
}

/// Count unmatched events and update the menubar display
fn updateUnmatchedCount(conn: c.duckdb_connection, allocator: std.mem.Allocator) void {
    var event_repo = DuckDbEventRepository.init(conn, allocator);
    const count = event_repo.countUnmatchedEvents();
    update_unmatched_count(count);
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

    // Load configuration
    var cfg = config_mod.load(allocator) catch |err| {
        std.debug.print("Warning: Failed to load config: {}. Using defaults.\n", .{err});
        return;
    };
    defer cfg.deinit(allocator);

    // Configure WiFi-based tracking
    if (cfg.tracking_wifi) |wifi| {
        std.debug.print("Tracking WiFi: {s}\n", .{wifi});
        // Null-terminate for C interop
        var wifi_buf: [128]u8 = undefined;
        if (wifi.len < wifi_buf.len) {
            @memcpy(wifi_buf[0..wifi.len], wifi);
            wifi_buf[wifi.len] = 0;
            set_tracking_wifi(&wifi_buf);
        }
    } else {
        std.debug.print("Tracking WiFi: (all networks)\n", .{});
        clear_tracking_wifi();
    }

    const db_path = getDbPath(allocator) catch |err| {
        std.debug.print("Failed to determine database path: {}\n", .{err});
        return;
    };
    // Don't defer free - we need this for the lifetime of the daemon
    global_db_path = db_path;
    global_allocator = allocator;

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
