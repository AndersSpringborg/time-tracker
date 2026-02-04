//! CLI Entry Point using Clean Architecture
//!
//! This is the new entry point that uses AppContext to wire up all dependencies.
//! Commands delegate to use cases and repositories via the composition root.

const std = @import("std");
const AppContext = @import("app_context").AppContext;
const query_repo = @import("query_repository");
const hierarchy_repo = @import("hierarchy_repository");
const domain_rule = @import("domain_rule");
const Rule = domain_rule.Rule;

// Legacy modules (still needed for complex workflows)
const review = @import("review");
const picker = @import("picker");
const migrations = @import("migrations");
const c = migrations.c;

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

    if (std.mem.eql(u8, command, "summary")) {
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

        var dur_buf: [32]u8 = undefined;
        const duration = formatDuration(event.duration_ms, &dur_buf);

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

            reviewer.mapEvent(event.id, selected.activity_id, selected.kind_id, true) catch |err| {
                std.debug.print("Failed to map event: {}\n", .{err});
                continue;
            };

            std.debug.print("Mapped to: {s}\n\n", .{selected.display_path});
            i += 1;
        }
    }

    std.debug.print("\nReview complete!\n", .{});
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
