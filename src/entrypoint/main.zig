const std = @import("std");
const config = @import("config");
const migrations = @import("migrations");
const c = migrations.c;

const Tracker = @import("tracker").Tracker;
const BufferedRepository = @import("buffered_repository").BufferedRepository;
const DuckDbRuleRepository = @import("duckdb_rule_repository").DuckDbRuleRepository;
const DuckDbHierarchyRepository = @import("duckdb_hierarchy_repository").DuckDbHierarchyRepository;
const DuckDbEventRepository = @import("duckdb_event_repository").DuckDbEventRepository;

extern fn check_accessibility() bool;
extern fn start_listening(cb: *const fn ([*c]const u8, [*c]const u8, [*c]const u8, i32) callconv(.c) void) void;
extern fn add_work_wifi(pattern: [*c]const u8) void;
extern fn clear_work_wifis() void;
extern fn update_matched_info(project: [*c]const u8, activity: [*c]const u8) void;
extern fn clear_matched_info() void;
extern fn update_unmatched_count(count: i64) void;

var global_tracker: ?*Tracker = null;
var global_allocator: ?std.mem.Allocator = null;
var global_db_path: ?[:0]const u8 = null;
var global_daemon_db_path_buf: [640]u8 = undefined;

const ActivityKind = struct {
    activity_id: i64,
    kind_id: i64,
};

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
        \\  ./tracker rules suggest --format json
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

fn getCurrentProjectId(conn: c.duckdb_connection) ?i64 {
    var result: c.duckdb_result = undefined;
    const sql =
        \\SELECT project_id
        \\FROM project_assignments
        \\WHERE ended_at IS NULL
        \\ORDER BY started_at DESC
        \\LIMIT 1
    ;

    if (c.duckdb_query(conn, sql, &result) == c.DuckDBError) {
        c.duckdb_destroy_result(&result);
        return null;
    }
    defer c.duckdb_destroy_result(&result);

    if (c.duckdb_row_count(&result) == 0) return null;
    return c.duckdb_value_int64(&result, 0, 0);
}

fn getLastMappedActivityKind(conn: c.duckdb_connection) ?ActivityKind {
    var result: c.duckdb_result = undefined;
    const sql =
        \\SELECT activity_id, kind_id
        \\FROM events
        \\WHERE activity_id IS NOT NULL AND kind_id IS NOT NULL
        \\ORDER BY timestamp_ms DESC, id DESC
        \\LIMIT 1
    ;

    if (c.duckdb_query(conn, sql, &result) == c.DuckDBError) {
        c.duckdb_destroy_result(&result);
        return null;
    }
    defer c.duckdb_destroy_result(&result);

    if (c.duckdb_row_count(&result) == 0) return null;

    return .{
        .activity_id = c.duckdb_value_int64(&result, 0, 0),
        .kind_id = c.duckdb_value_int64(&result, 1, 0),
    };
}

fn updateUnmatchedCount(conn: c.duckdb_connection, allocator: std.mem.Allocator) void {
    var event_repo = DuckDbEventRepository.init(conn, allocator);
    const count = event_repo.countUnmatchedEvents();
    update_unmatched_count(count);
}

fn matchAndUpdateMenubar(app: []const u8, title: []const u8) void {
    const allocator = global_allocator orelse return;
    const db_path = global_db_path orelse return;

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

    const current_project_id = getCurrentProjectId(conn);

    var rule_repo = DuckDbRuleRepository.init(conn, allocator);
    const match_result = rule_repo.findMatchWithContext(app, title, current_project_id) catch {
        clear_matched_info();
        return;
    };

    if (match_result) |match| {
        const resolved_kind_id = switch (match.action) {
            .map_kind => match.kind_id orelse {
                clear_matched_info();
                return;
            },
            .follow_previous => blk: {
                const previous = getLastMappedActivityKind(conn) orelse {
                    clear_matched_info();
                    return;
                };
                break :blk previous.kind_id;
            },
        };

        var hierarchy_repo_impl = DuckDbHierarchyRepository.init(conn, allocator);
        const names = hierarchy_repo_impl.getProjectAndActivityForKind(resolved_kind_id) catch {
            clear_matched_info();
            return;
        };
        defer {
            allocator.free(@constCast(names.project));
            allocator.free(@constCast(names.activity));
        }

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

    updateUnmatchedCount(conn, allocator);
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

    std.debug.print("[Event] App: {s} | Title: {s} | WiFi: {s}\n", .{ app, title, wifi });

    if (global_tracker) |tracker| {
        tracker.onEventWithWifi(app, title, wifi, timestamp);
    }

    matchAndUpdateMenubar(app, title);
}

fn getDaemonDbPath() ![:0]const u8 {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const xdg_data = std.posix.getenv("XDG_DATA_HOME");

    var path_buf: [512]u8 = undefined;
    var path_len: usize = 0;

    if (xdg_data) |data_dir| {
        path_len = (std.fmt.bufPrint(&path_buf, "{s}/time-tracker", .{data_dir}) catch return error.PathTooLong).len;
    } else {
        path_len = (std.fmt.bufPrint(&path_buf, "{s}/.local/share/time-tracker", .{home}) catch return error.PathTooLong).len;
    }

    const dir_path = path_buf[0..path_len];
    std.fs.makeDirAbsolute(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("Warning: Could not create data directory: {s}\n", .{dir_path});
        }
    };

    const full_path = std.fmt.bufPrint(&global_daemon_db_path_buf, "{s}/tracker.db", .{dir_path}) catch return error.PathTooLong;
    global_daemon_db_path_buf[full_path.len] = 0;
    return global_daemon_db_path_buf[0..full_path.len :0];
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

fn runDaemonCore(allocator: std.mem.Allocator) void {
    const db_path = getDaemonDbPath() catch |err| {
        std.debug.print("Failed to determine database path: {}\n", .{err});
        return;
    };
    global_db_path = db_path;
    global_allocator = allocator;
    defer {
        global_db_path = null;
        global_allocator = null;
    }

    std.debug.print("Database: {s}\n", .{db_path});

    var repo = BufferedRepository.init(allocator, db_path);
    defer repo.deinit();

    repo.startFlushTimer() catch |err| {
        std.debug.print("Failed to start flush timer: {}\n", .{err});
        return;
    };

    std.debug.print("Buffered repository initialized (flushes after 5s of inactivity).\n", .{});

    var tracker = Tracker.init(&repo);
    global_tracker = &tracker;
    defer global_tracker = null;

    if (!check_accessibility()) {
        std.debug.print("\nWarning: Accessibility not yet granted. Will report error on start.\n", .{});
    }

    std.debug.print("\nStarting event listener... (switch windows to see events)\n", .{});
    std.debug.print("Press Ctrl+C to exit.\n\n", .{});

    start_listening(&onEvent);
}
