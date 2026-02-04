//! CLI Entry Point using Clean Architecture
//!
//! This is the unified entry point for both CLI commands and the daemon.
//! Commands delegate to use cases and repositories via the composition root.
//! The daemon command integrates with Swift for macOS event tracking.

const std = @import("std");
const AppContext = @import("app_context").AppContext;
const query_repo = @import("query_repository");
const hierarchy_repo = @import("hierarchy_repository");
const domain_rule = @import("domain_rule");
const Rule = domain_rule.Rule;

// Legacy modules (still needed for complex workflows)
const review = @import("review");
const review_tui = @import("review_tui");
const picker = @import("picker");
const migrations = @import("migrations");
const c = migrations.c;

// Daemon modules
const Tracker = @import("tracker").Tracker;
const BufferedRepository = @import("buffered_repository").BufferedRepository;

// Import functions from Swift bridge
extern fn check_accessibility() bool;
extern fn start_listening(cb: *const fn ([*c]const u8, [*c]const u8, [*c]const u8, i32) callconv(.c) void) void;

// Global state (needed for C callback from Swift)
var global_tracker: ?*Tracker = null;
var global_repo: ?*BufferedRepository = null;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command-line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "daemon")) {
        runDaemon(allocator);
    } else if (std.mem.eql(u8, command, "summary")) {
        runSummary(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "report")) {
        runReport(allocator, args[2..]);
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
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{command});
        printUsage();
    }
}

fn printUsage() void {
    const usage =
        \\Usage: tt <command> [options]
        \\
        \\Commands:
        \\  daemon         Start the time tracking daemon (macOS)
        \\  summary        Show time spent per application
        \\  report         Show detailed report with window titles
        \\  import         Import customer hierarchy from JSON file
        \\  rules          Manage mapping rules
        \\  apply-rules    Apply rules to unmapped events
        \\  review         Interactively review and map unmapped events
        \\  projects       Manage active project context
        \\  help           Show this help message
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
        \\  tt daemon              # Start tracking in background
        \\  tt summary --today
        \\  tt report --week
        \\  tt import customers.json
        \\  tt rules list
        \\  tt review
        \\  tt projects add
        \\
    ;
    std.debug.print("{s}", .{usage});
}

const TimeRange = enum {
    today,
    week,
    all,
};

fn parseTimeRange(args: []const [:0]const u8) TimeRange {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--week")) return .week;
        if (std.mem.eql(u8, arg, "--all")) return .all;
        if (std.mem.eql(u8, arg, "--today")) return .today;
    }
    return .today;
}

fn formatDuration(ms: i64, buf: []u8) []const u8 {
    const total_seconds = @divFloor(ms, 1000);
    const hours = @divFloor(total_seconds, 3600);
    const minutes = @divFloor(@mod(total_seconds, 3600), 60);

    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}h {d}m", .{ hours, minutes }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d}m", .{minutes}) catch "?";
    }
}

/// Read a line from stdin into the provided buffer
fn readLine(buf: []u8) ![]u8 {
    const bytes_read = std.posix.read(std.posix.STDIN_FILENO, buf) catch |err| {
        return err;
    };

    if (bytes_read == 0) {
        return error.EndOfStream;
    }

    return buf[0..bytes_read];
}

// =============================================================================
// SUMMARY COMMAND
// =============================================================================

fn runSummary(allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    const ctx = AppContext.init(allocator) catch |err| {
        std.debug.print("Failed to initialize: {}\n", .{err});
        return;
    };
    defer ctx.deinit();

    const range = parseTimeRange(args);
    const range_label = switch (range) {
        .today => "Today",
        .week => "Last 7 Days",
        .all => "All Time",
    };

    std.debug.print("\n=== Time Summary ({s}) ===\n\n", .{range_label});

    const query_range = switch (range) {
        .today => query_repo.TimeRange.today,
        .week => query_repo.TimeRange.week,
        .all => query_repo.TimeRange.all,
    };

    // Get total time
    const total_ms = ctx.queryRepo.getTotalTrackedTime(query_range) catch 0;
    var total_buf: [32]u8 = undefined;
    std.debug.print("Total tracked: {s}\n\n", .{formatDuration(total_ms, &total_buf)});

    // Get per-app summary
    const summaries = ctx.queryRepo.getAppSummary(query_range) catch |err| {
        std.debug.print("Failed to query: {}\n", .{err});
        return;
    };
    defer ctx.queryRepo.freeAppSummaries(summaries);

    if (summaries.len == 0) {
        std.debug.print("No data recorded yet.\n", .{});
        return;
    }

    std.debug.print("{s:<30} {s:>12}\n", .{ "Application", "Time" });
    std.debug.print("{s:-<30} {s:->12}\n", .{ "", "" });

    for (summaries) |summary| {
        var dur_buf: [32]u8 = undefined;
        const duration = formatDuration(summary.total_ms, &dur_buf);
        std.debug.print("{s:<30} {s:>12}\n", .{ summary.app_name, duration });
    }

    std.debug.print("\n", .{});
}

// =============================================================================
// REPORT COMMAND
// =============================================================================

fn runReport(allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    const ctx = AppContext.init(allocator) catch |err| {
        std.debug.print("Failed to initialize: {}\n", .{err});
        return;
    };
    defer ctx.deinit();

    const range = parseTimeRange(args);
    const range_label = switch (range) {
        .today => "Today",
        .week => "Last 7 Days",
        .all => "All Time",
    };

    std.debug.print("\n=== Detailed Report ({s}) ===\n\n", .{range_label});

    const query_range = switch (range) {
        .today => query_repo.TimeRange.today,
        .week => query_repo.TimeRange.week,
        .all => query_repo.TimeRange.all,
    };

    // Get total time
    const total_ms = ctx.queryRepo.getTotalTrackedTime(query_range) catch 0;
    var total_buf: [32]u8 = undefined;
    std.debug.print("Total tracked: {s}\n", .{formatDuration(total_ms, &total_buf)});

    // Get per-app summary
    const summaries = ctx.queryRepo.getAppSummary(query_range) catch |err| {
        std.debug.print("Failed to query: {}\n", .{err});
        return;
    };
    defer ctx.queryRepo.freeAppSummaries(summaries);

    if (summaries.len == 0) {
        std.debug.print("No data recorded yet.\n", .{});
        return;
    }

    for (summaries) |summary| {
        var dur_buf: [32]u8 = undefined;
        const duration = formatDuration(summary.total_ms, &dur_buf);
        std.debug.print("\n{s} ({s})\n", .{ summary.app_name, duration });
        std.debug.print("{s:-<50}\n", .{""});

        // Get title details for this app
        const details = ctx.queryRepo.getTitleDetails(summary.app_name, query_range) catch continue;
        defer ctx.queryRepo.freeTitleDetails(details);

        for (details) |detail| {
            var detail_buf: [32]u8 = undefined;
            const detail_dur = formatDuration(detail.total_ms, &detail_buf);

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

// =============================================================================
// IMPORT COMMAND
// =============================================================================

fn runImport(allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    if (args.len < 1) {
        std.debug.print("Usage: tt import <customers.json>\n", .{});
        return;
    }

    const file_path = args[0];
    std.debug.print("Importing hierarchy from: {s}\n", .{file_path});

    const ctx = AppContext.init(allocator) catch |err| {
        std.debug.print("Failed to initialize: {}\n", .{err});
        return;
    };
    defer ctx.deinit();

    // Import hierarchy
    const stats = ctx.hierarchyRepo.importFromFile(file_path) catch |err| {
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

// =============================================================================
// RULES COMMAND
// =============================================================================

fn runRules(allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    const ctx = AppContext.init(allocator) catch |err| {
        std.debug.print("Failed to initialize: {}\n", .{err});
        return;
    };
    defer ctx.deinit();

    if (args.len < 1) {
        std.debug.print("Usage: tt rules <list|add|delete>\n", .{});
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "list")) {
        runRulesList(ctx);
    } else if (std.mem.eql(u8, subcommand, "add")) {
        runRulesAdd(ctx, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "delete")) {
        runRulesDelete(ctx, args[1..]);
    } else {
        std.debug.print("Unknown rules subcommand: {s}\n", .{subcommand});
    }
}

fn getKindPath(conn: c.duckdb_connection, kind_id: i64, allocator: std.mem.Allocator) ![]const u8 {
    var stmt: c.duckdb_prepared_statement = undefined;
    const sql =
        \\SELECT c.name || ' > ' || p.name || ' > ' || ph.name || ' > ' || a.name || ' > ' || k.name
        \\FROM kinds k
        \\JOIN activities a ON k.activity_id = a.activity_id
        \\JOIN time_phases ph ON a.phase_id = ph.phase_id
        \\JOIN projects p ON ph.project_id = p.project_id
        \\JOIN customers c ON p.customer_id = c.customer_id
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

    const path_ptr = c.duckdb_value_varchar(&result, 0, 0);
    if (path_ptr == null) {
        return error.NotFound;
    }
    defer c.duckdb_free(path_ptr);

    const path_len = std.mem.len(path_ptr);
    const path = try allocator.alloc(u8, path_len);
    @memcpy(path, path_ptr[0..path_len]);
    return path;
}

fn runRulesList(ctx: *AppContext) void {
    const fetched_rules = ctx.ruleRepo.listRules() catch |err| {
        std.debug.print("Failed to list rules: {}\n", .{err});
        return;
    };
    defer ctx.ruleRepo.freeRules(fetched_rules);

    if (fetched_rules.len == 0) {
        std.debug.print("No mapping rules defined.\n", .{});
        std.debug.print("Use 'tt rules add' to create one.\n", .{});
        return;
    }

    std.debug.print("\n=== Mapping Rules ===\n\n", .{});
    std.debug.print("{s:<6} {s:<20} {s:<25} {s:<40}\n", .{ "ID", "App Pattern", "Title Pattern", "Maps To" });
    std.debug.print("{s:-<6} {s:-<20} {s:-<25} {s:-<40}\n", .{ "", "", "", "" });

    var allocated_paths: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (allocated_paths.items) |path| {
            ctx.allocator.free(path);
        }
        allocated_paths.deinit(ctx.allocator);
    }

    for (fetched_rules) |rule| {
        const app_pat = rule.app_pattern orelse "(any)";
        const title_pat = rule.title_pattern orelse "(any)";

        var maps_to: []const u8 = undefined;
        var needs_free = false;

        if (rule.is_global) {
            if (rule.kind_name) |kind_name| {
                const formatted = std.fmt.allocPrint(ctx.allocator, "(global) {s}", .{kind_name}) catch "(global) ???";
                maps_to = formatted;
                needs_free = true;
            } else {
                maps_to = "(global) ???";
            }
        } else {
            maps_to = getKindPath(ctx.getConnection(), rule.kind_id, ctx.allocator) catch "(unknown)";
            needs_free = !std.mem.eql(u8, maps_to, "(unknown)");
        }

        if (needs_free) {
            allocated_paths.append(ctx.allocator, maps_to) catch {};
        }

        var id_buf: [16]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{rule.id}) catch "?";
        std.debug.print("{s:<6} {s:<20} {s:<25} {s:<40}\n", .{ id_str, app_pat, title_pat, maps_to });
    }

    std.debug.print("\n", .{});
}

fn runRulesAdd(ctx: *AppContext, args: []const [:0]const u8) void {
    _ = ctx;
    _ = args;
    std.debug.print("Interactive rule adding not yet implemented in new CLI.\n", .{});
    std.debug.print("Use the legacy 'time_tracker rules add' command for now.\n", .{});
}

fn runRulesDelete(ctx: *AppContext, args: []const [:0]const u8) void {
    if (args.len < 1) {
        std.debug.print("Usage: tt rules delete <rule_id>\n", .{});
        return;
    }

    const rule_id = std.fmt.parseInt(i64, args[0], 10) catch {
        std.debug.print("Invalid rule ID: {s}\n", .{args[0]});
        return;
    };

    ctx.ruleRepo.deleteRule(rule_id) catch |err| {
        std.debug.print("Failed to delete rule: {}\n", .{err});
        return;
    };

    std.debug.print("Deleted rule {d}.\n", .{rule_id});
}

// =============================================================================
// APPLY-RULES COMMAND
// =============================================================================

fn runApplyRules(allocator: std.mem.Allocator) void {
    const ctx = AppContext.init(allocator) catch |err| {
        std.debug.print("Failed to initialize: {}\n", .{err});
        return;
    };
    defer ctx.deinit();

    const conn = ctx.getConnection();

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

        const match = ctx.ruleRepo.findMatch(app_name, title) catch continue;
        if (match) |m| {
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

// =============================================================================
// REVIEW COMMAND
// =============================================================================

fn runReview(allocator: std.mem.Allocator) void {
    const ctx = AppContext.init(allocator) catch |err| {
        std.debug.print("Failed to initialize: {}\n", .{err});
        return;
    };
    defer ctx.deinit();

    const conn = ctx.getConnection();

    // Run the TUI
    review_tui.run(allocator, conn) catch |err| {
        std.debug.print("Review TUI error: {}\n", .{err});
        return;
    };
}

// =============================================================================
// PROJECTS COMMAND
// =============================================================================

fn runProjects(allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    const ctx = AppContext.init(allocator) catch |err| {
        std.debug.print("Failed to initialize: {}\n", .{err});
        return;
    };
    defer ctx.deinit();

    if (args.len < 1) {
        runProjectsList(ctx);
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "list")) {
        runProjectsList(ctx);
    } else if (std.mem.eql(u8, subcommand, "add")) {
        runProjectsAdd(ctx);
    } else if (std.mem.eql(u8, subcommand, "end")) {
        runProjectsEnd(ctx, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "clear")) {
        runProjectsClear(ctx);
    } else {
        std.debug.print("Unknown projects subcommand: {s}\n", .{subcommand});
        std.debug.print("Usage: tt projects <list|add|end|clear>\n", .{});
    }
}

fn getProjectName(conn: c.duckdb_connection, project_id: i64, allocator: std.mem.Allocator) ![]const u8 {
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
    defer c.duckdb_free(name_ptr);

    const name_len = std.mem.len(name_ptr);
    const name = try allocator.alloc(u8, name_len);
    @memcpy(name, name_ptr[0..name_len]);
    return name;
}

fn runProjectsList(ctx: *AppContext) void {
    const active_ids = ctx.projectRepo.getActiveProjectIds() catch |err| {
        std.debug.print("Failed to get active projects: {}\n", .{err});
        return;
    };
    defer ctx.projectRepo.freeProjectIds(active_ids);

    if (active_ids.len == 0) {
        std.debug.print("No active projects.\n", .{});
        std.debug.print("Use 'tt projects add' to set your current project context.\n", .{});
        return;
    }

    std.debug.print("\n=== Active Projects ===\n\n", .{});

    for (active_ids) |project_id| {
        const name = getProjectName(ctx.getConnection(), project_id, ctx.allocator) catch "Unknown";
        defer if (!std.mem.eql(u8, name, "Unknown")) ctx.allocator.free(name);
        std.debug.print("  [{d}] {s}\n", .{ project_id, name });
    }

    std.debug.print("\n", .{});
}

fn runProjectsAdd(ctx: *AppContext) void {
    const conn = ctx.getConnection();
    const allocator = ctx.allocator;

    // Get all projects
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
        std.debug.print("No projects found. Import a hierarchy first with 'tt import'.\n", .{});
        return;
    }

    // Build picker items
    var items = allocator.alloc(picker.PickerItem, row_count) catch {
        std.debug.print("Out of memory\n", .{});
        return;
    };
    defer allocator.free(items);

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

    const active_ids = ctx.projectRepo.getActiveProjectIds() catch &[_]i64{};
    defer if (active_ids.len > 0) ctx.projectRepo.freeProjectIds(active_ids);

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

    ctx.projectRepo.addProject(selection.selected_id) catch |err| {
        std.debug.print("Failed to add project: {}\n", .{err});
        return;
    };

    const selected_name = items[selection.selected_index].display_text;
    std.debug.print("Added project: {s}\n", .{selected_name});
}

fn runProjectsEnd(ctx: *AppContext, args: []const [:0]const u8) void {
    if (args.len < 1) {
        std.debug.print("Usage: tt projects end <project_id>\n", .{});
        std.debug.print("Use 'tt projects list' to see active project IDs.\n", .{});
        return;
    }

    const project_id = std.fmt.parseInt(i64, args[0], 10) catch {
        std.debug.print("Invalid project ID: {s}\n", .{args[0]});
        return;
    };

    ctx.projectRepo.endProject(project_id) catch |err| {
        std.debug.print("Failed to end project: {}\n", .{err});
        return;
    };

    std.debug.print("Ended project {d}.\n", .{project_id});
}

fn runProjectsClear(ctx: *AppContext) void {
    ctx.projectRepo.endAllProjects() catch |err| {
        std.debug.print("Failed to clear projects: {}\n", .{err});
        return;
    };

    std.debug.print("Cleared all active projects.\n", .{});
}

// =============================================================================
// DAEMON COMMAND
// =============================================================================

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

fn getDaemonDbPath(allocator: std.mem.Allocator) ![:0]const u8 {
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

fn runDaemon(allocator: std.mem.Allocator) void {
    std.debug.print("=== Time Tracker Daemon ===\n\n", .{});

    const db_path = getDaemonDbPath(allocator) catch |err| {
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
