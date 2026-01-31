const std = @import("std");
const Tracker = @import("tracker").Tracker;
const DuckDbRepository = @import("duckdb_repository").DuckDbRepository;
const query = @import("query");
const migrations = @import("migrations");
const hierarchy = @import("hierarchy");
const rules = @import("rules");

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
        \\  daemon         Start the time tracking daemon
        \\  summary        Show time spent per application
        \\  report         Show detailed report with window titles
        \\  import         Import customer hierarchy from JSON file
        \\  rules          Manage mapping rules
        \\  apply-rules    Apply rules to unmapped events
        \\  review         Interactively review and map unmapped events
        \\
        \\Options for summary/report:
        \\  --today        Show only today's data (default)
        \\  --week         Show last 7 days
        \\  --all          Show all time
        \\
        \\Rules subcommands:
        \\  rules list     List all mapping rules
        \\  rules add      Add a new rule (interactive)
        \\  rules delete   Delete a rule by ID
        \\
        \\Examples:
        \\  time_tracker daemon
        \\  time_tracker summary --today
        \\  time_tracker report --week
        \\  time_tracker import customers.json
        \\  time_tracker rules list
        \\  time_tracker review
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

fn runImport(allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    if (args.len < 1) {
        std.debug.print("Usage: time_tracker import <customers.json>\n", .{});
        return;
    }

    const file_path = args[0];
    std.debug.print("Importing hierarchy from: {s}\n", .{file_path});

    const db_path = getDbPath(allocator) catch |err| {
        std.debug.print("Failed to determine database path: {}\n", .{err});
        return;
    };
    defer allocator.free(db_path);

    // Open database connection
    const c = migrations.c;
    var db: c.duckdb_database = undefined;
    var conn: c.duckdb_connection = undefined;

    if (c.duckdb_open(db_path.ptr, &db) == c.DuckDBError) {
        std.debug.print("Failed to open database\n", .{});
        return;
    }
    defer c.duckdb_close(&db);

    if (c.duckdb_connect(db, &conn) == c.DuckDBError) {
        std.debug.print("Failed to connect to database\n", .{});
        return;
    }
    defer c.duckdb_disconnect(&conn);

    // Run migrations first
    var migrator = migrations.Migrator.init(conn) catch |err| {
        std.debug.print("Failed to init migrator: {}\n", .{err});
        return;
    };
    migrator.run() catch |err| {
        std.debug.print("Failed to run migrations: {}\n", .{err});
        return;
    };

    // Import hierarchy
    var importer = hierarchy.HierarchyImporter.init(conn, allocator);
    const stats = importer.importFromFile(file_path) catch |err| {
        std.debug.print("Import failed: {}\n", .{err});
        return;
    };

    std.debug.print("\nImport successful!\n", .{});
    std.debug.print("  Customers:  {d}\n", .{stats.customers});
    std.debug.print("  Projects:   {d}\n", .{stats.projects});
    std.debug.print("  Phases:     {d}\n", .{stats.phases});
    std.debug.print("  Activities: {d}\n", .{stats.activities});
    std.debug.print("  Kinds:      {d}\n", .{stats.kinds});
}

fn runRules(allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    const db_path = getDbPath(allocator) catch |err| {
        std.debug.print("Failed to determine database path: {}\n", .{err});
        return;
    };
    defer allocator.free(db_path);

    const c = migrations.c;
    var db: c.duckdb_database = undefined;
    var conn: c.duckdb_connection = undefined;

    if (c.duckdb_open(db_path.ptr, &db) == c.DuckDBError) {
        std.debug.print("Failed to open database\n", .{});
        return;
    }
    defer c.duckdb_close(&db);

    if (c.duckdb_connect(db, &conn) == c.DuckDBError) {
        std.debug.print("Failed to connect to database\n", .{});
        return;
    }
    defer c.duckdb_disconnect(&conn);

    // Run migrations first
    var migrator = migrations.Migrator.init(conn) catch |err| {
        std.debug.print("Failed to init migrator: {}\n", .{err});
        return;
    };
    migrator.run() catch |err| {
        std.debug.print("Failed to run migrations: {}\n", .{err});
        return;
    };

    var engine = rules.RulesEngine.init(conn, allocator);

    if (args.len < 1) {
        std.debug.print("Usage: time_tracker rules <list|add|delete>\n", .{});
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "list")) {
        runRulesList(&engine);
    } else if (std.mem.eql(u8, subcommand, "add")) {
        runRulesAdd(&engine, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "delete")) {
        runRulesDelete(&engine, args[1..]);
    } else {
        std.debug.print("Unknown rules subcommand: {s}\n", .{subcommand});
    }
}

fn runRulesList(engine: *rules.RulesEngine) void {
    const fetched_rules = engine.listRules() catch |err| {
        std.debug.print("Failed to list rules: {}\n", .{err});
        return;
    };
    defer engine.allocator.free(fetched_rules);

    if (fetched_rules.len == 0) {
        std.debug.print("No mapping rules defined.\n", .{});
        std.debug.print("Use 'time_tracker rules add' to create one.\n", .{});
        return;
    }

    std.debug.print("\n{s:<6} {s:<8} {s:<20} {s:<25} {s:<12} {s:<8}\n", .{ "ID", "Priority", "App Pattern", "Title Pattern", "Activity ID", "Kind ID" });
    std.debug.print("{s:-<6} {s:-<8} {s:-<20} {s:-<25} {s:-<12} {s:-<8}\n", .{ "", "", "", "", "", "" });

    for (fetched_rules) |rule| {
        const app = rule.app_pattern orelse "(any)";
        const title = rule.title_pattern orelse "(any)";
        std.debug.print("{d:<6} {d:<8} {s:<20} {s:<25} {d:<12} {d:<8}\n", .{
            rule.id,
            rule.priority,
            app,
            title,
            rule.activity_id,
            rule.kind_id,
        });
    }
    std.debug.print("\n", .{});
}

fn runRulesAdd(engine: *rules.RulesEngine, args: []const [:0]const u8) void {
    // Parse args: --app <pattern> --title <pattern> --activity <id> --kind <id> --priority <n>
    var app_pattern: ?[]const u8 = null;
    var title_pattern: ?[]const u8 = null;
    var activity_id: ?i64 = null;
    var kind_id: ?i64 = null;
    var priority: i32 = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--app") and i + 1 < args.len) {
            i += 1;
            app_pattern = args[i];
        } else if (std.mem.eql(u8, arg, "--title") and i + 1 < args.len) {
            i += 1;
            title_pattern = args[i];
        } else if (std.mem.eql(u8, arg, "--activity") and i + 1 < args.len) {
            i += 1;
            activity_id = std.fmt.parseInt(i64, args[i], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--kind") and i + 1 < args.len) {
            i += 1;
            kind_id = std.fmt.parseInt(i64, args[i], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--priority") and i + 1 < args.len) {
            i += 1;
            priority = std.fmt.parseInt(i32, args[i], 10) catch 0;
        }
    }

    if (activity_id == null or kind_id == null) {
        std.debug.print("Usage: time_tracker rules add --app <pattern> --title <pattern> --activity <id> --kind <id> [--priority <n>]\n", .{});
        std.debug.print("\nRequired: --activity and --kind\n", .{});
        std.debug.print("Patterns support * wildcards (e.g., 'IntelliJ*', '*money*')\n", .{});
        return;
    }

    engine.addRule(.{
        .app_pattern = app_pattern,
        .title_pattern = title_pattern,
        .activity_id = activity_id.?,
        .kind_id = kind_id.?,
        .priority = priority,
    }) catch |err| {
        std.debug.print("Failed to add rule: {}\n", .{err});
        return;
    };

    std.debug.print("Rule added successfully.\n", .{});
}

fn runRulesDelete(engine: *rules.RulesEngine, args: []const [:0]const u8) void {
    if (args.len < 1) {
        std.debug.print("Usage: time_tracker rules delete <rule_id>\n", .{});
        return;
    }

    const rule_id = std.fmt.parseInt(i64, args[0], 10) catch {
        std.debug.print("Invalid rule ID: {s}\n", .{args[0]});
        return;
    };

    engine.deleteRule(rule_id) catch |err| {
        std.debug.print("Failed to delete rule: {}\n", .{err});
        return;
    };

    std.debug.print("Rule {d} deleted.\n", .{rule_id});
}

fn runApplyRules(allocator: std.mem.Allocator) void {
    const db_path = getDbPath(allocator) catch |err| {
        std.debug.print("Failed to determine database path: {}\n", .{err});
        return;
    };
    defer allocator.free(db_path);

    const c = migrations.c;
    var db: c.duckdb_database = undefined;
    var conn: c.duckdb_connection = undefined;

    if (c.duckdb_open(db_path.ptr, &db) == c.DuckDBError) {
        std.debug.print("Failed to open database\n", .{});
        return;
    }
    defer c.duckdb_close(&db);

    if (c.duckdb_connect(db, &conn) == c.DuckDBError) {
        std.debug.print("Failed to connect to database\n", .{});
        return;
    }
    defer c.duckdb_disconnect(&conn);

    // Run migrations first
    var migrator = migrations.Migrator.init(conn) catch |err| {
        std.debug.print("Failed to init migrator: {}\n", .{err});
        return;
    };
    migrator.run() catch |err| {
        std.debug.print("Failed to run migrations: {}\n", .{err});
        return;
    };

    var engine = rules.RulesEngine.init(conn, allocator);

    // Get unmapped events
    var result: c.duckdb_result = undefined;
    const query_sql = "SELECT id, app_name, window_title FROM events WHERE activity_id IS NULL AND manually_mapped = false";

    if (c.duckdb_query(conn, query_sql, &result) == c.DuckDBError) {
        std.debug.print("Failed to query events\n", .{});
        return;
    }
    defer c.duckdb_destroy_result(&result);

    const row_count = c.duckdb_row_count(&result);
    var matched: u64 = 0;

    for (0..row_count) |i| {
        const row: c.idx_t = @intCast(i);
        const event_id = c.duckdb_value_int64(&result, 0, row);
        const app_name_ptr = c.duckdb_value_varchar(&result, 1, row);
        const title_ptr = c.duckdb_value_varchar(&result, 2, row);

        if (app_name_ptr == null or title_ptr == null) continue;

        const app_name = std.mem.sliceTo(app_name_ptr, 0);
        const title = std.mem.sliceTo(title_ptr, 0);

        const match = engine.findMatch(app_name, title) catch continue;
        if (match) |m| {
            // Update the event
            var update_stmt: c.duckdb_prepared_statement = undefined;
            const update_sql = "UPDATE events SET activity_id = ?, kind_id = ? WHERE id = ?";

            if (c.duckdb_prepare(conn, update_sql, &update_stmt) == c.DuckDBError) continue;
            defer c.duckdb_destroy_prepare(&update_stmt);

            _ = c.duckdb_bind_int64(update_stmt, 1, m.activity_id);
            _ = c.duckdb_bind_int64(update_stmt, 2, m.kind_id);
            _ = c.duckdb_bind_int64(update_stmt, 3, event_id);

            var update_result: c.duckdb_result = undefined;
            if (c.duckdb_execute_prepared(update_stmt, &update_result) == c.DuckDBError) {
                c.duckdb_destroy_result(&update_result);
                continue;
            }
            c.duckdb_destroy_result(&update_result);

            matched += 1;
        }
    }

    std.debug.print("Applied rules to {d} events (out of {d} unmapped).\n", .{ matched, row_count });
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
    } else if (std.mem.eql(u8, command, "import")) {
        runImport(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "rules")) {
        runRules(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "apply-rules")) {
        runApplyRules(allocator);
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{command});
        printUsage();
    }
}
