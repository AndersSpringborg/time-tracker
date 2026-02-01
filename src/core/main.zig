const std = @import("std");
const Tracker = @import("tracker").Tracker;
const DuckDbRepository = @import("duckdb_repository").DuckDbRepository;
const BufferedRepository = @import("buffered_repository").BufferedRepository;
const query = @import("query");
const migrations = @import("migrations");
const hierarchy = @import("hierarchy");
const rules = @import("rules");
const review = @import("review");
const context = @import("context");
const picker = @import("picker");

// Import functions from Swift bridge (only used in daemon mode)
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
        \\  projects       Manage active project context
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
        \\Projects subcommands:
        \\  projects list  List active projects
        \\  projects add   Add a project to active context (interactive picker)
        \\  projects end   End an active project
        \\  projects clear End all active projects
        \\
        \\Examples:
        \\  time_tracker daemon
        \\  time_tracker summary --today
        \\  time_tracker report --week
        \\  time_tracker import customers.json
        \\  time_tracker rules list
        \\  time_tracker review
        \\  time_tracker projects add
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
    // Note: We don't defer free here since the daemon runs forever
    // and the path is needed by the buffered repository

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

/// Read a line from stdin into the provided buffer, returning a slice of the data read.
fn readLine(buf: []u8) ![]u8 {
    const bytes_read = std.posix.read(std.posix.STDIN_FILENO, buf) catch |err| {
        return err;
    };

    if (bytes_read == 0) {
        return error.EndOfStream;
    }

    return buf[0..bytes_read];
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
        runRulesList(&engine, conn, allocator);
    } else if (std.mem.eql(u8, subcommand, "add")) {
        runRulesAdd(&engine, conn, allocator, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "delete")) {
        runRulesDelete(&engine, args[1..]);
    } else {
        std.debug.print("Unknown rules subcommand: {s}\n", .{subcommand});
    }
}

fn runRulesList(engine: *rules.RulesEngine, conn: migrations.c.duckdb_connection, allocator: std.mem.Allocator) void {
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

    std.debug.print("\n=== Mapping Rules ===\n\n", .{});
    std.debug.print("{s:<6} {s:<20} {s:<25} {s:<40}\n", .{ "ID", "App Pattern", "Title Pattern", "Maps To" });
    std.debug.print("{s:-<6} {s:-<20} {s:-<25} {s:-<40}\n", .{ "", "", "", "" });

    // Track allocated path strings to free them after the loop
    var allocated_paths: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (allocated_paths.items) |path| {
            allocator.free(path);
        }
        allocated_paths.deinit(allocator);
    }

    for (fetched_rules) |rule| {
        const app_pat = rule.app_pattern orelse "(any)";
        const title_pat = rule.title_pattern orelse "(any)";

        // Get the kind's full path
        const maps_to = getKindPath(conn, rule.kind_id, allocator) catch "(unknown)";
        // Track allocation for cleanup (only if we allocated it)
        if (!std.mem.eql(u8, maps_to, "(unknown)")) {
            allocated_paths.append(allocator, maps_to) catch {};
        }

        std.debug.print("{d:<6} {s:<20} {s:<25} {s:<40}\n", .{
            rule.id,
            truncateStr(app_pat, 18),
            truncateStr(title_pat, 23),
            truncateStr(maps_to, 38),
        });
    }
    std.debug.print("\n", .{});
}

fn runRulesAdd(engine: *rules.RulesEngine, conn: migrations.c.duckdb_connection, allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    // Require app pattern as argument
    if (args.len == 0) {
        std.debug.print("Usage: time_tracker rules add <app_pattern>\n", .{});
        std.debug.print("\nExamples:\n", .{});
        std.debug.print("  time_tracker rules add Slack\n", .{});
        std.debug.print("  time_tracker rules add 'IntelliJ*'\n", .{});
        std.debug.print("  time_tracker rules add '*'\n", .{});
        std.debug.print("\nPatterns support * wildcards for matching.\n", .{});
        return;
    }

    const app_pattern: []const u8 = args[0];

    // Query all kinds with their full hierarchy path
    const c = migrations.c;
    const query_sql =
        \\SELECT k.kind_id, k.activity_id,
        \\       cu.name || ' > ' || p.name || ' > ' || ph.name || ' > ' || a.name || ' > ' || k.name as full_path
        \\FROM kinds k
        \\JOIN activities a ON k.activity_id = a.activity_id
        \\JOIN phases ph ON a.phase_id = ph.phase_id
        \\JOIN projects p ON ph.project_id = p.project_id
        \\JOIN customers cu ON p.customer_id = cu.customer_id
        \\ORDER BY cu.name, p.name, ph.name, a.name, k.name
    ;

    var result: c.duckdb_result = undefined;
    if (c.duckdb_query(conn, query_sql, &result) == c.DuckDBError) {
        std.debug.print("Failed to query kinds\n", .{});
        return;
    }
    defer c.duckdb_destroy_result(&result);

    const row_count = c.duckdb_row_count(&result);
    if (row_count == 0) {
        std.debug.print("No kinds found. Import your customer hierarchy first:\n", .{});
        std.debug.print("  time_tracker import customers.json\n", .{});
        return;
    }

    // Build picker items
    var items = allocator.alloc(picker.PickerItem, row_count) catch {
        std.debug.print("Out of memory\n", .{});
        return;
    };
    defer allocator.free(items);

    var strings = allocator.alloc([]const u8, row_count) catch {
        std.debug.print("Out of memory\n", .{});
        return;
    };
    defer {
        for (strings) |s| allocator.free(s);
        allocator.free(strings);
    }

    var kind_ids = allocator.alloc(i64, row_count) catch {
        std.debug.print("Out of memory\n", .{});
        return;
    };
    defer allocator.free(kind_ids);

    var activity_ids = allocator.alloc(i64, row_count) catch {
        std.debug.print("Out of memory\n", .{});
        return;
    };
    defer allocator.free(activity_ids);

    for (0..row_count) |i| {
        const row: c.idx_t = @intCast(i);
        kind_ids[i] = c.duckdb_value_int64(&result, 0, row);
        activity_ids[i] = c.duckdb_value_int64(&result, 1, row);

        const path_ptr = c.duckdb_value_varchar(&result, 2, row);
        if (path_ptr != null) {
            const path_len = std.mem.len(path_ptr);
            const path_copy = allocator.alloc(u8, path_len) catch {
                strings[i] = "(error)";
                continue;
            };
            @memcpy(path_copy, path_ptr[0..path_len]);
            strings[i] = path_copy;
            c.duckdb_free(path_ptr);
        } else {
            strings[i] = "(unknown)";
        }

        items[i] = .{
            .id = kind_ids[i],
            .display_text = strings[i],
            .secondary_text = "",
            .is_highlighted = false,
        };
    }

    // Show picker
    std.debug.print("Creating rule for app pattern: {s}\n", .{app_pattern});
    std.debug.print("Select the kind to map to:\n\n", .{});

    var p = picker.Picker.init(allocator, items, "Select Kind to Map To") catch |err| {
        if (err == picker.PickerError.NotATty) {
            std.debug.print("Error: Interactive mode requires a terminal.\n", .{});
        } else {
            std.debug.print("Failed to initialize picker: {}\n", .{err});
        }
        return;
    };
    defer p.deinit();

    const selection = p.run() catch |err| {
        if (err == picker.PickerError.Cancelled) {
            std.debug.print("Cancelled.\n", .{});
        }
        return;
    };

    const selected_kind_id = kind_ids[selection.selected_index];
    const selected_activity_id = activity_ids[selection.selected_index];

    // Add the rule
    engine.addRule(.{
        .app_pattern = app_pattern,
        .title_pattern = null,
        .activity_id = selected_activity_id,
        .kind_id = selected_kind_id,
        .priority = 0,
    }) catch |err| {
        std.debug.print("Failed to add rule: {}\n", .{err});
        return;
    };

    std.debug.print("Rule added: '{s}' -> {s}\n", .{ app_pattern, strings[selection.selected_index] });
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

fn runReview(allocator: std.mem.Allocator) void {
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

    var reviewer = review.Reviewer.init(conn, allocator);

    // Get unmapped events
    const events = reviewer.getUnmappedEvents() catch |err| {
        std.debug.print("Failed to get unmapped events: {}\n", .{err});
        return;
    };
    defer allocator.free(events);

    if (events.len == 0) {
        std.debug.print("No unmapped events to review.\n", .{});
        return;
    }

    std.debug.print("\n=== Interactive Event Review ===\n", .{});
    std.debug.print("Found {d} unmapped events.\n\n", .{events.len});

    var input_buf: [512]u8 = undefined;

    var i: usize = 0;
    while (i < events.len) {
        const event = events[i];

        // Format duration
        var dur_buf: [32]u8 = undefined;
        const duration = query.formatDuration(event.duration_ms, &dur_buf);

        std.debug.print("--- Event {d}/{d} ---\n", .{ i + 1, events.len });
        std.debug.print("App:      {s}\n", .{event.app_name});
        std.debug.print("Title:    {s}\n", .{event.window_title});
        std.debug.print("Duration: {s}\n", .{duration});
        std.debug.print("\nActions: [s]earch, [n]ext, [q]uit\n", .{});
        std.debug.print("> ", .{});

        const line = readLine(&input_buf) catch {
            std.debug.print("\nGoodbye!\n", .{});
            return;
        };

        const trimmed = std.mem.trim(u8, line, " \t\r\n");

        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "n")) {
            i += 1;
            continue;
        }

        if (std.mem.eql(u8, trimmed, "q")) {
            std.debug.print("\nExiting review.\n", .{});
            return;
        }

        if (std.mem.eql(u8, trimmed, "s") or std.mem.startsWith(u8, trimmed, "s ")) {
            // Search mode - prompt for search term
            var search_term: []const u8 = undefined;

            if (trimmed.len > 2) {
                search_term = trimmed[2..];
            } else {
                std.debug.print("Enter search term: ", .{});
                const search_line = readLine(&input_buf) catch {
                    continue;
                };
                search_term = std.mem.trim(u8, search_line, " \t\r\n");
            }

            if (search_term.len == 0) {
                continue;
            }

            // Search the hierarchy
            const matches = reviewer.searchFullHierarchy(search_term) catch |err| {
                std.debug.print("Search failed: {}\n", .{err});
                continue;
            };
            defer {
                for (matches) |m| {
                    allocator.free(m.display_path);
                }
                allocator.free(matches);
            }

            if (matches.len == 0) {
                std.debug.print("No matches found for '{s}'.\n\n", .{search_term});
                continue;
            }

            std.debug.print("\nSearch results:\n", .{});
            for (matches, 0..) |m, idx| {
                std.debug.print("  [{d}] {s}\n", .{ idx + 1, m.display_path });
            }
            std.debug.print("  [0] Cancel\n", .{});
            std.debug.print("\nSelect (1-{d}): ", .{matches.len});

            const select_line = readLine(&input_buf) catch {
                continue;
            };
            const select_trimmed = std.mem.trim(u8, select_line, " \t\r\n");
            const selection = std.fmt.parseInt(usize, select_trimmed, 10) catch {
                std.debug.print("Invalid selection.\n\n", .{});
                continue;
            };

            if (selection == 0 or selection > matches.len) {
                std.debug.print("Cancelled.\n\n", .{});
                continue;
            }

            const selected = matches[selection - 1];

            // Map the event
            reviewer.mapEvent(event.id, selected.activity_id, selected.kind_id, true) catch |err| {
                std.debug.print("Failed to map event: {}\n", .{err});
                continue;
            };

            std.debug.print("Event mapped to: {s}\n", .{selected.display_path});

            // Ask if they want to create a rule
            std.debug.print("\nCreate rule for similar events? [y/N]: ", .{});
            const rule_line = readLine(&input_buf) catch {
                i += 1;
                continue;
            };
            const rule_trimmed = std.mem.trim(u8, rule_line, " \t\r\n");

            if (std.mem.eql(u8, rule_trimmed, "y") or std.mem.eql(u8, rule_trimmed, "Y")) {
                // Ask for patterns
                std.debug.print("App pattern (default: '{s}'): ", .{event.app_name});
                const app_line = readLine(&input_buf) catch {
                    i += 1;
                    continue;
                };
                var app_pattern = std.mem.trim(u8, app_line, " \t\r\n");
                if (app_pattern.len == 0) {
                    app_pattern = event.app_name;
                }

                std.debug.print("Title pattern (default: '*', current: '{s}'): ", .{event.window_title});
                const title_line = readLine(&input_buf) catch {
                    i += 1;
                    continue;
                };
                var title_pattern = std.mem.trim(u8, title_line, " \t\r\n");
                if (title_pattern.len == 0) {
                    title_pattern = "*";
                }

                // Create the rule
                var engine = rules.RulesEngine.init(conn, allocator);
                engine.addRule(.{
                    .app_pattern = app_pattern,
                    .title_pattern = if (std.mem.eql(u8, title_pattern, "*")) null else title_pattern,
                    .activity_id = selected.activity_id,
                    .kind_id = selected.kind_id,
                    .priority = 0,
                }) catch |err| {
                    std.debug.print("Failed to create rule: {}\n", .{err});
                    i += 1;
                    continue;
                };

                std.debug.print("Rule created: app='{s}', title='{s}'\n", .{ app_pattern, title_pattern });
            }

            i += 1;
            std.debug.print("\n", .{});
        }
    }

    std.debug.print("\nReview complete!\n", .{});
}

fn runProjects(allocator: std.mem.Allocator, args: []const [:0]const u8) void {
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

    var ctx = context.ProjectContext.init(conn, allocator);

    if (args.len < 1) {
        // Default to list
        runProjectsList(&ctx, allocator, conn);
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "list")) {
        runProjectsList(&ctx, allocator, conn);
    } else if (std.mem.eql(u8, subcommand, "add")) {
        runProjectsAdd(&ctx, allocator, conn);
    } else if (std.mem.eql(u8, subcommand, "end")) {
        runProjectsEnd(&ctx, allocator, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "clear")) {
        runProjectsClear(&ctx);
    } else {
        std.debug.print("Unknown projects subcommand: {s}\n", .{subcommand});
        std.debug.print("Usage: time_tracker projects <list|add|end|clear>\n", .{});
    }
}

fn runProjectsList(ctx: *context.ProjectContext, allocator: std.mem.Allocator, conn: migrations.c.duckdb_connection) void {
    const active = ctx.getActiveProjects() catch |err| {
        std.debug.print("Failed to get active projects: {}\n", .{err});
        return;
    };
    defer allocator.free(active);

    if (active.len == 0) {
        std.debug.print("No active projects.\n", .{});
        std.debug.print("Use 'time_tracker projects add' to set your current project context.\n", .{});
        return;
    }

    std.debug.print("\n=== Active Projects ===\n\n", .{});

    for (active) |assignment| {
        // Get project name
        const name = getProjectName(conn, assignment.project_id, allocator) catch "Unknown";
        defer if (!std.mem.eql(u8, name, "Unknown")) allocator.free(name);
        std.debug.print("  [{d}] {s}\n", .{ assignment.project_id, name });
    }

    std.debug.print("\n", .{});
}

fn runProjectsAdd(ctx: *context.ProjectContext, allocator: std.mem.Allocator, conn: migrations.c.duckdb_connection) void {
    // Get all projects
    const c = migrations.c;
    var result: c.duckdb_result = undefined;
    const sql =
        \\SELECT p.project_id, c.name || ' > ' || p.name as display_name 
        \\FROM projects p 
        \\JOIN customers c ON p.customer_id = c.customer_id
        \\ORDER BY c.name, p.name
    ;

    if (c.duckdb_query(conn, sql, &result) == c.DuckDBError) {
        std.debug.print("Failed to query projects\n", .{});
        return;
    }
    defer c.duckdb_destroy_result(&result);

    const row_count = c.duckdb_row_count(&result);
    if (row_count == 0) {
        std.debug.print("No projects found. Import a hierarchy first with 'time_tracker import'.\n", .{});
        return;
    }

    // Build picker items
    var items = allocator.alloc(picker.PickerItem, row_count) catch {
        std.debug.print("Out of memory\n", .{});
        return;
    };
    defer allocator.free(items);

    // Allocate string storage
    var strings = allocator.alloc([]u8, row_count) catch {
        std.debug.print("Out of memory\n", .{});
        return;
    };
    defer {
        for (strings) |s| {
            allocator.free(s);
        }
        allocator.free(strings);
    }

    // Get active project IDs for highlighting
    const active_ids = ctx.getActiveProjectIds() catch &[_]i64{};
    defer if (active_ids.len > 0) allocator.free(active_ids);

    for (0..row_count) |i| {
        const idx: c.idx_t = @intCast(i);
        const project_id = c.duckdb_value_int64(&result, 0, idx);
        const name_ptr = c.duckdb_value_varchar(&result, 1, idx);

        var name_len: usize = 0;
        if (name_ptr != null) {
            name_len = std.mem.len(name_ptr);
        }

        strings[i] = allocator.alloc(u8, name_len) catch {
            continue;
        };
        if (name_ptr != null) {
            @memcpy(strings[i], name_ptr[0..name_len]);
            c.duckdb_free(name_ptr);
        }

        const is_active = blk: {
            for (active_ids) |aid| {
                if (aid == project_id) break :blk true;
            }
            break :blk false;
        };

        items[i] = .{
            .id = project_id,
            .display_text = strings[i],
            .secondary_text = if (is_active) "active" else "",
            .is_highlighted = is_active,
        };
    }

    // Run picker
    var p = picker.Picker.init(allocator, items, "Select Project to Add") catch |err| {
        if (err == picker.PickerError.NotATty) {
            std.debug.print("Error: Interactive mode requires a terminal (not piped).\n", .{});
        } else {
            std.debug.print("Failed to initialize picker: {}\n", .{err});
        }
        return;
    };
    defer p.deinit();

    const selection = p.run() catch |err| {
        if (err == picker.PickerError.Cancelled) {
            std.debug.print("Cancelled.\n", .{});
        }
        return;
    };

    // Add the project
    ctx.addProject(selection.selected_id) catch |err| {
        std.debug.print("Failed to add project: {}\n", .{err});
        return;
    };

    const selected_name = items[selection.selected_index].display_text;
    std.debug.print("Added project: {s}\n", .{selected_name});
}

fn runProjectsEnd(ctx: *context.ProjectContext, allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    if (args.len < 1) {
        std.debug.print("Usage: time_tracker projects end <project_id>\n", .{});
        std.debug.print("Use 'time_tracker projects list' to see active project IDs.\n", .{});
        return;
    }

    const project_id = std.fmt.parseInt(i64, args[0], 10) catch {
        std.debug.print("Invalid project ID: {s}\n", .{args[0]});
        return;
    };

    const is_active = ctx.isProjectActive(project_id) catch false;
    if (!is_active) {
        std.debug.print("Project {d} is not currently active.\n", .{project_id});
        return;
    }

    ctx.endProject(project_id) catch |err| {
        std.debug.print("Failed to end project: {}\n", .{err});
        return;
    };

    std.debug.print("Project {d} ended.\n", .{project_id});
    _ = allocator;
}

fn runProjectsClear(ctx: *context.ProjectContext) void {
    ctx.endAllProjects() catch |err| {
        std.debug.print("Failed to clear projects: {}\n", .{err});
        return;
    };

    std.debug.print("All active projects cleared.\n", .{});
}

fn getProjectName(conn: migrations.c.duckdb_connection, project_id: i64, allocator: std.mem.Allocator) ![]const u8 {
    const c = migrations.c;
    var stmt: c.duckdb_prepared_statement = undefined;
    const sql = "SELECT c.name || ' > ' || p.name FROM projects p JOIN customers c ON p.customer_id = c.customer_id WHERE p.project_id = ?";

    if (c.duckdb_prepare(conn, sql, &stmt) == c.DuckDBError) {
        return error.QueryFailed;
    }
    defer c.duckdb_destroy_prepare(&stmt);

    _ = c.duckdb_bind_int64(stmt, 1, project_id);

    var result: c.duckdb_result = undefined;
    if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
        return error.QueryFailed;
    }
    defer c.duckdb_destroy_result(&result);

    if (c.duckdb_row_count(&result) == 0) {
        return error.NotFound;
    }

    const name_ptr = c.duckdb_value_varchar(&result, 0, 0);
    if (name_ptr == null) {
        return error.NotFound;
    }

    const name_len = std.mem.len(name_ptr);
    const name_copy = try allocator.alloc(u8, name_len);
    @memcpy(name_copy, name_ptr[0..name_len]);
    c.duckdb_free(name_ptr);

    return name_copy;
}

/// Get the full path for a kind (Customer > Project > Phase > Activity > Kind)
fn getKindPath(conn: migrations.c.duckdb_connection, kind_id: i64, allocator: std.mem.Allocator) ![]const u8 {
    const c = migrations.c;
    var stmt: c.duckdb_prepared_statement = undefined;
    const sql =
        \\SELECT cu.name || ' > ' || p.name || ' > ' || k.name
        \\FROM kinds k
        \\JOIN activities a ON k.activity_id = a.activity_id
        \\JOIN phases ph ON a.phase_id = ph.phase_id
        \\JOIN projects p ON ph.project_id = p.project_id
        \\JOIN customers cu ON p.customer_id = cu.customer_id
        \\WHERE k.kind_id = ?
    ;

    if (c.duckdb_prepare(conn, sql, &stmt) == c.DuckDBError) {
        return error.QueryFailed;
    }
    defer c.duckdb_destroy_prepare(&stmt);

    _ = c.duckdb_bind_int64(stmt, 1, kind_id);

    var result: c.duckdb_result = undefined;
    if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
        return error.QueryFailed;
    }
    defer c.duckdb_destroy_result(&result);

    if (c.duckdb_row_count(&result) == 0) {
        return error.NotFound;
    }

    const name_ptr = c.duckdb_value_varchar(&result, 0, 0);
    if (name_ptr == null) {
        return error.NotFound;
    }

    const name_len = std.mem.len(name_ptr);
    const name_copy = try allocator.alloc(u8, name_len);
    @memcpy(name_copy, name_ptr[0..name_len]);
    c.duckdb_free(name_ptr);

    return name_copy;
}

/// Truncate a string with ellipsis if too long
fn truncateStr(str: []const u8, max_len: usize) []const u8 {
    if (str.len <= max_len) return str;
    return str[0..max_len];
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
    } else if (std.mem.eql(u8, command, "review")) {
        runReview(allocator);
    } else if (std.mem.eql(u8, command, "projects")) {
        runProjects(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{command});
        printUsage();
    }
}
