//! CLI Entry Point using Clean Architecture
//!
//! This is the unified entry point for both CLI commands and the daemon.
//! Commands delegate to use cases and repositories via the composition root.
//! The daemon command integrates with Swift for macOS event tracking.

const std = @import("std");
const glob = @import("glob");
const AppContext = @import("app_context").AppContext;
const query_repo = @import("query_repository");
const hierarchy_repo = @import("hierarchy_repository");
const domain_rule = @import("domain_rule");
const Rule = domain_rule.Rule;
const config = @import("config");
const project_weighted_report_usecase = @import("project_weighted_report_usecase");
const time_weighted_project = @import("time_weighted_project");

// Legacy modules (still needed for complex workflows)
const review = @import("review");
const review_tui = @import("review_tui");
const picker = @import("picker");
const migrations = @import("migrations");
const c = migrations.c;

// Daemon modules
const Tracker = @import("tracker").Tracker;
const BufferedRepository = @import("buffered_repository").BufferedRepository;
const DuckDbRuleRepository = @import("duckdb_rule_repository").DuckDbRuleRepository;
const DuckDbHierarchyRepository = @import("duckdb_hierarchy_repository").DuckDbHierarchyRepository;
const DuckDbEventRepository = @import("duckdb_event_repository").DuckDbEventRepository;

// Import functions from Swift bridge
extern fn check_accessibility() bool;
extern fn start_listening(cb: *const fn ([*c]const u8, [*c]const u8, [*c]const u8, i32) callconv(.c) void) void;
extern fn add_work_wifi(pattern: [*c]const u8) void;
extern fn clear_work_wifis() void;
extern fn get_wifi_ssid() ?[*:0]const u8;
extern fn update_matched_info(project: [*c]const u8, activity: [*c]const u8) void;
extern fn clear_matched_info() void;
extern fn update_unmatched_count(count: i64) void;

// Global state (needed for C callback from Swift)
var global_tracker: ?*Tracker = null;
var global_repo: ?*BufferedRepository = null;
var global_allocator: ?std.mem.Allocator = null;
var global_db_path: ?[:0]const u8 = null;

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
    } else if (std.mem.eql(u8, command, "config")) {
        runConfig(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "wifi")) {
        runWifi(allocator, args[2..]);
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
        \\  config         View and edit configuration
        \\  wifi           Manage work WiFi networks for location-based tracking
        \\  help           Show this help message
        \\
        \\Options for summary/report:
        \\  --today        Show only today's data (default)
        \\  --week         Show last 7 days
        \\  --all          Show all time
        \\  --weighted-projects  Report by weighted project timeline
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
        \\Config subcommands:
        \\  config list           List all settings
        \\  config get <key>      Get a setting value
        \\  config set <key> <v>  Set a setting value
        \\  config unset <key>    Reset to default
        \\
        \\WiFi subcommands:
        \\  wifi list             List configured work WiFi patterns
        \\  wifi add              Add current WiFi to work list
        \\  wifi add <pattern>    Add a pattern (supports * and ? globs)
        \\  wifi remove <pattern> Remove a pattern from work list
        \\
        \\Examples:
        \\  tt daemon              # Start tracking in background
        \\  tt summary --today
        \\  tt report --week
        \\  tt import customers.json
        \\  tt rules list
        \\  tt review
        \\  tt projects add
        \\  tt wifi add            # Add current WiFi network
        \\  tt wifi add "Office*"  # Add pattern matching Office, Office-5G, etc.
        \\
    ;
    std.debug.print("{s}", .{usage});
}

const TimeRange = enum {
    today,
    week,
    all,
};

const ReportView = enum {
    detailed,
    weighted_projects,
};

fn parseTimeRange(args: []const [:0]const u8) TimeRange {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--week")) return .week;
        if (std.mem.eql(u8, arg, "--all")) return .all;
        if (std.mem.eql(u8, arg, "--today")) return .today;
    }
    return .today;
}

fn parseReportView(args: []const [:0]const u8) ReportView {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--weighted-projects")) return .weighted_projects;
    }
    return .detailed;
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

const ReportEvent = struct {
    timestamp_ms: i64,
    duration_ms: i64,
    app_name: []u8,
    window_title: []u8,
    project_id: ?i64,
};

const AppSummaryRow = struct {
    app_name: []u8,
    total_ms: i64,
};

const TitleSummaryRow = struct {
    window_title: []u8,
    total_ms: i64,
};

fn fetchReportEvents(
    conn: c.duckdb_connection,
    allocator: std.mem.Allocator,
    range: query_repo.TimeRange,
) ![]ReportEvent {
    const where_clause = switch (range) {
        .today => "WHERE e.timestamp_ms >= (extract(epoch from current_date) * 1000)",
        .week => "WHERE e.timestamp_ms >= (extract(epoch from current_date - interval '7 days') * 1000)",
        .all => "",
    };

    var query_buf: [1024]u8 = undefined;
    const query = std.fmt.bufPrintZ(&query_buf,
        \\SELECT e.timestamp_ms, e.duration_ms, e.app_name, e.window_title, ph.project_id
        \\FROM events e
        \\LEFT JOIN activities a ON e.activity_id = a.activity_id
        \\LEFT JOIN phases ph ON a.phase_id = ph.phase_id
        \\{s}
        \\ORDER BY e.timestamp_ms ASC
    , .{where_clause}) catch return error.QueryFailed;

    var result: c.duckdb_result = undefined;
    if (c.duckdb_query(conn, query.ptr, &result) == c.DuckDBError) {
        return error.QueryFailed;
    }
    defer c.duckdb_destroy_result(&result);

    const row_count = c.duckdb_row_count(&result);
    var events = allocator.alloc(ReportEvent, row_count) catch return error.OutOfMemory;
    errdefer allocator.free(events);

    for (0..row_count) |i| {
        const row: c.idx_t = @intCast(i);

        const app_ptr = c.duckdb_value_varchar(&result, 2, row);
        defer if (app_ptr != null) c.duckdb_free(app_ptr);
        const app_len = if (app_ptr != null) std.mem.len(app_ptr) else 0;
        const app_name = allocator.alloc(u8, app_len) catch {
            for (events[0..i]) |event| {
                allocator.free(event.app_name);
                allocator.free(event.window_title);
            }
            allocator.free(events);
            return error.OutOfMemory;
        };
        if (app_ptr != null and app_len > 0) {
            @memcpy(app_name, app_ptr[0..app_len]);
        }

        const title_ptr = c.duckdb_value_varchar(&result, 3, row);
        defer if (title_ptr != null) c.duckdb_free(title_ptr);
        const title_len = if (title_ptr != null) std.mem.len(title_ptr) else 0;
        const window_title = allocator.alloc(u8, title_len) catch {
            allocator.free(app_name);
            for (events[0..i]) |event| {
                allocator.free(event.app_name);
                allocator.free(event.window_title);
            }
            allocator.free(events);
            return error.OutOfMemory;
        };
        if (title_ptr != null and title_len > 0) {
            @memcpy(window_title, title_ptr[0..title_len]);
        }

        events[i] = .{
            .timestamp_ms = c.duckdb_value_int64(&result, 0, row),
            .duration_ms = c.duckdb_value_int64(&result, 1, row),
            .app_name = app_name,
            .window_title = window_title,
            .project_id = if (c.duckdb_value_is_null(&result, 4, row)) null else c.duckdb_value_int64(&result, 4, row),
        };
    }

    return events;
}

fn freeReportEvents(allocator: std.mem.Allocator, events: []ReportEvent) void {
    for (events) |event| {
        allocator.free(event.app_name);
        allocator.free(event.window_title);
    }
    allocator.free(events);
}

fn isNoiseApp(cfg: config.Config, app_name: []const u8) bool {
    for (cfg.noise_app_patterns) |pattern| {
        if (glob.match(pattern, app_name)) return true;
    }
    return false;
}

fn applySimpleNoiseMask(cfg: config.Config, events: []const ReportEvent, excluded: []bool) void {
    for (events, 0..) |event, i| {
        excluded[i] = isNoiseApp(cfg, event.app_name);
    }
}

fn isNoiseMidpoint(midpoint_ms: i64, intervals: []const time_weighted_project.ProjectInterval) bool {
    for (intervals) |interval| {
        if (interval.project_id != 1) continue;
        if (midpoint_ms >= interval.start_ms and midpoint_ms < interval.end_ms) {
            return true;
        }
    }
    return false;
}

fn buildNoiseMask(
    allocator: std.mem.Allocator,
    events: []const ReportEvent,
    cfg: config.Config,
) ![]bool {
    const excluded = allocator.alloc(bool, events.len) catch return error.OutOfMemory;
    @memset(excluded, false);

    if (events.len == 0 or cfg.noise_app_patterns.len == 0) {
        return excluded;
    }

    var slices: std.ArrayListUnmanaged(time_weighted_project.ProjectSlice) = .{};
    defer slices.deinit(allocator);

    for (events) |event| {
        if (event.duration_ms <= 0) continue;

        slices.append(allocator, .{
            .project_id = if (isNoiseApp(cfg, event.app_name)) 1 else 2,
            .start_ms = event.timestamp_ms,
            .end_ms = event.timestamp_ms + event.duration_ms,
        }) catch {
            applySimpleNoiseMask(cfg, events, excluded);
            return excluded;
        };
    }

    if (slices.items.len == 0) {
        applySimpleNoiseMask(cfg, events, excluded);
        return excluded;
    }

    const minute_ms: i64 = 60 * 1000;
    const weighted_cfg = time_weighted_project.TimeWeightedConfig{
        .bucket_size_ms = cfg.noise_bucket_minutes * minute_ms,
        .switch_threshold_ms = cfg.noise_switch_minutes * minute_ms,
    };

    const buckets = time_weighted_project.TimeWeightedProjector.computeBuckets(allocator, slices.items, weighted_cfg) catch {
        applySimpleNoiseMask(cfg, events, excluded);
        return excluded;
    };
    defer allocator.free(buckets);

    const smoothed = time_weighted_project.TimeWeightedProjector.smoothBuckets(allocator, buckets, weighted_cfg) catch {
        applySimpleNoiseMask(cfg, events, excluded);
        return excluded;
    };
    defer allocator.free(smoothed);

    const intervals = time_weighted_project.TimeWeightedProjector.mergeBucketsToIntervals(allocator, smoothed) catch {
        applySimpleNoiseMask(cfg, events, excluded);
        return excluded;
    };
    defer allocator.free(intervals);

    for (events, 0..) |event, i| {
        if (event.duration_ms <= 0) {
            excluded[i] = isNoiseApp(cfg, event.app_name);
            continue;
        }

        const midpoint_ms = event.timestamp_ms + @divFloor(event.duration_ms, 2);
        excluded[i] = isNoiseMidpoint(midpoint_ms, intervals);
    }

    return excluded;
}

fn totalTrackedMs(events: []const ReportEvent, excluded: []const bool) i64 {
    var total: i64 = 0;
    for (events, 0..) |event, i| {
        if (excluded[i]) continue;
        if (event.duration_ms > 0) total += event.duration_ms;
    }
    return total;
}

fn countExcludedEvents(excluded: []const bool) usize {
    var count: usize = 0;
    for (excluded) |is_excluded| {
        if (is_excluded) count += 1;
    }
    return count;
}

fn summarizeByApp(
    allocator: std.mem.Allocator,
    events: []const ReportEvent,
    excluded: []const bool,
) ![]AppSummaryRow {
    var items: std.ArrayListUnmanaged(AppSummaryRow) = .{};
    errdefer {
        for (items.items) |item| allocator.free(item.app_name);
        items.deinit(allocator);
    }

    for (events, 0..) |event, i| {
        if (excluded[i] or event.duration_ms <= 0) continue;

        var found = false;
        for (items.items) |*item| {
            if (std.mem.eql(u8, item.app_name, event.app_name)) {
                item.total_ms += event.duration_ms;
                found = true;
                break;
            }
        }

        if (!found) {
            const app_copy = allocator.dupe(u8, event.app_name) catch return error.OutOfMemory;
            items.append(allocator, .{
                .app_name = app_copy,
                .total_ms = event.duration_ms,
            }) catch return error.OutOfMemory;
        }
    }

    std.mem.sort(AppSummaryRow, items.items, {}, struct {
        fn lessThan(_: void, lhs: AppSummaryRow, rhs: AppSummaryRow) bool {
            if (lhs.total_ms == rhs.total_ms) {
                return std.mem.lessThan(u8, lhs.app_name, rhs.app_name);
            }
            return lhs.total_ms > rhs.total_ms;
        }
    }.lessThan);

    return items.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn freeAppSummaries(allocator: std.mem.Allocator, summaries: []AppSummaryRow) void {
    for (summaries) |summary| allocator.free(summary.app_name);
    allocator.free(summaries);
}

fn summarizeTitlesForApp(
    allocator: std.mem.Allocator,
    events: []const ReportEvent,
    excluded: []const bool,
    app_name: []const u8,
) ![]TitleSummaryRow {
    var items: std.ArrayListUnmanaged(TitleSummaryRow) = .{};
    errdefer {
        for (items.items) |item| allocator.free(item.window_title);
        items.deinit(allocator);
    }

    for (events, 0..) |event, i| {
        if (excluded[i] or event.duration_ms <= 0) continue;
        if (!std.mem.eql(u8, event.app_name, app_name)) continue;

        var found = false;
        for (items.items) |*item| {
            if (std.mem.eql(u8, item.window_title, event.window_title)) {
                item.total_ms += event.duration_ms;
                found = true;
                break;
            }
        }

        if (!found) {
            const title_copy = allocator.dupe(u8, event.window_title) catch return error.OutOfMemory;
            items.append(allocator, .{
                .window_title = title_copy,
                .total_ms = event.duration_ms,
            }) catch return error.OutOfMemory;
        }
    }

    std.mem.sort(TitleSummaryRow, items.items, {}, struct {
        fn lessThan(_: void, lhs: TitleSummaryRow, rhs: TitleSummaryRow) bool {
            if (lhs.total_ms == rhs.total_ms) {
                return std.mem.lessThan(u8, lhs.window_title, rhs.window_title);
            }
            return lhs.total_ms > rhs.total_ms;
        }
    }.lessThan);

    if (items.items.len > 10) {
        for (items.items[10..]) |item| allocator.free(item.window_title);
        const trimmed = allocator.alloc(TitleSummaryRow, 10) catch return error.OutOfMemory;
        @memcpy(trimmed, items.items[0..10]);
        items.deinit(allocator);
        return trimmed;
    }

    return items.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn freeTitleSummaries(allocator: std.mem.Allocator, titles: []TitleSummaryRow) void {
    for (titles) |title| allocator.free(title.window_title);
    allocator.free(titles);
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

    var cfg = config.load(allocator) catch config.Config{};
    defer cfg.deinit(allocator);

    const events = fetchReportEvents(ctx.getConnection(), allocator, query_range) catch |err| {
        std.debug.print("Failed to query events: {}\n", .{err});
        return;
    };
    defer freeReportEvents(allocator, events);

    const excluded = buildNoiseMask(allocator, events, cfg) catch |err| {
        std.debug.print("Failed to filter noise: {}\n", .{err});
        return;
    };
    defer allocator.free(excluded);

    const summaries = summarizeByApp(allocator, events, excluded) catch |err| {
        std.debug.print("Failed to build summary: {}\n", .{err});
        return;
    };
    defer freeAppSummaries(allocator, summaries);

    const total_ms = totalTrackedMs(events, excluded);
    var total_buf: [32]u8 = undefined;
    std.debug.print("Total tracked: {s}\n\n", .{formatDuration(total_ms, &total_buf)});

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

    const report_view = parseReportView(args);
    if (report_view == .weighted_projects) {
        runWeightedProjectReport(ctx, allocator, query_range, range_label);
        return;
    }

    var cfg = config.load(allocator) catch config.Config{};
    defer cfg.deinit(allocator);

    const events = fetchReportEvents(ctx.getConnection(), allocator, query_range) catch |err| {
        std.debug.print("Failed to query events: {}\n", .{err});
        return;
    };
    defer freeReportEvents(allocator, events);

    const excluded = buildNoiseMask(allocator, events, cfg) catch |err| {
        std.debug.print("Failed to filter noise: {}\n", .{err});
        return;
    };
    defer allocator.free(excluded);

    const summaries = summarizeByApp(allocator, events, excluded) catch |err| {
        std.debug.print("Failed to build summary: {}\n", .{err});
        return;
    };
    defer freeAppSummaries(allocator, summaries);

    const total_ms = totalTrackedMs(events, excluded);
    var total_buf: [32]u8 = undefined;
    std.debug.print("Total tracked: {s}\n", .{formatDuration(total_ms, &total_buf)});

    if (summaries.len == 0) {
        std.debug.print("No data recorded yet.\n", .{});
        return;
    }

    for (summaries) |summary| {
        var dur_buf: [32]u8 = undefined;
        const duration = formatDuration(summary.total_ms, &dur_buf);
        std.debug.print("\n{s} ({s})\n", .{ summary.app_name, duration });
        std.debug.print("{s:-<50}\n", .{""});

        const details = summarizeTitlesForApp(allocator, events, excluded, summary.app_name) catch continue;
        defer freeTitleSummaries(allocator, details);

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

fn runWeightedProjectReport(
    ctx: *AppContext,
    allocator: std.mem.Allocator,
    query_range: query_repo.TimeRange,
    range_label: []const u8,
) void {
    var cfg = config.load(allocator) catch config.Config{};
    defer cfg.deinit(allocator);

    const events = fetchReportEvents(ctx.getConnection(), allocator, query_range) catch |err| {
        std.debug.print("Failed to query events: {}\n", .{err});
        return;
    };
    defer freeReportEvents(allocator, events);

    const excluded = buildNoiseMask(allocator, events, cfg) catch |err| {
        std.debug.print("Failed to filter noise: {}\n", .{err});
        return;
    };
    defer allocator.free(excluded);

    var candidate_list: std.ArrayListUnmanaged(query_repo.ProjectEventCandidate) = .{};
    defer candidate_list.deinit(allocator);

    for (events, 0..) |event, i| {
        if (excluded[i]) continue;
        candidate_list.append(allocator, .{
            .timestamp_ms = event.timestamp_ms,
            .duration_ms = event.duration_ms,
            .project_id = event.project_id,
        }) catch |err| {
            std.debug.print("Failed to prepare weighted report candidates: {}\n", .{err});
            return;
        };
    }

    const filtered_candidates = candidate_list.items;

    const FilteredQueryRepository = struct {
        allocator: std.mem.Allocator,
        candidates: []const query_repo.ProjectEventCandidate,

        pub fn init(allocator_: std.mem.Allocator, candidates_: []const query_repo.ProjectEventCandidate) @This() {
            return .{
                .allocator = allocator_,
                .candidates = candidates_,
            };
        }

        pub fn getAppSummary(self: *@This(), _: query_repo.TimeRange) query_repo.QueryRepositoryError![]query_repo.AppSummary {
            return self.allocator.alloc(query_repo.AppSummary, 0) catch return error.OutOfMemory;
        }

        pub fn getTitleDetails(self: *@This(), _: []const u8, _: query_repo.TimeRange) query_repo.QueryRepositoryError![]query_repo.TitleDetail {
            return self.allocator.alloc(query_repo.TitleDetail, 0) catch return error.OutOfMemory;
        }

        pub fn getTotalTrackedTime(self: *@This(), _: query_repo.TimeRange) query_repo.QueryRepositoryError!i64 {
            var total: i64 = 0;
            for (self.candidates) |candidate| {
                if (candidate.duration_ms > 0) total += candidate.duration_ms;
            }
            return total;
        }

        pub fn getProjectName(_: *@This(), _: i64) query_repo.QueryRepositoryError!?[]const u8 {
            return null;
        }

        pub fn getProjectEventCandidates(self: *@This(), _: query_repo.TimeRange) query_repo.QueryRepositoryError![]query_repo.ProjectEventCandidate {
            const copy = self.allocator.alloc(query_repo.ProjectEventCandidate, self.candidates.len) catch return error.OutOfMemory;
            @memcpy(copy, self.candidates);
            return copy;
        }

        pub fn freeAppSummaries(self: *@This(), summaries: []query_repo.AppSummary) void {
            for (summaries) |summary| {
                if (summary.app_name.len > 0) self.allocator.free(@constCast(summary.app_name));
            }
            self.allocator.free(summaries);
        }

        pub fn freeTitleDetails(self: *@This(), details: []query_repo.TitleDetail) void {
            for (details) |detail| {
                if (detail.window_title.len > 0) self.allocator.free(@constCast(detail.window_title));
            }
            self.allocator.free(details);
        }

        pub fn freeProjectEventCandidates(self: *@This(), candidates: []query_repo.ProjectEventCandidate) void {
            self.allocator.free(candidates);
        }

        pub fn freeName(self: *@This(), name: []const u8) void {
            self.allocator.free(@constCast(name));
        }

        pub fn repository(self: *@This()) query_repo.QueryRepository {
            return query_repo.QueryRepository.init(self);
        }
    };

    var filtered_repo = FilteredQueryRepository.init(allocator, filtered_candidates);

    const minute_ms: i64 = 60 * 1000;
    var usecase = project_weighted_report_usecase.ProjectWeightedReportUseCase.init(
        filtered_repo.repository(),
        .{
            .bucket_size_ms = cfg.weighted_bucket_minutes * minute_ms,
            .switch_threshold_ms = cfg.weighted_switch_minutes * minute_ms,
        },
    );

    var report = usecase.run(allocator, query_range) catch |err| {
        std.debug.print("Failed to compute weighted project report: {}\n", .{err});
        return;
    };
    defer report.deinit(allocator);

    std.debug.print("\n=== Weighted Project Report ({s}) ===\n\n", .{range_label});
    std.debug.print(
        "Bucket: {d}m  Switch threshold: {d}m\n",
        .{ cfg.weighted_bucket_minutes, cfg.weighted_switch_minutes },
    );
    std.debug.print(
        "Source events: {d}  Noise excluded: {d}  Mapped events: {d}  Excluded unmapped: {d}\n\n",
        .{ events.len, countExcludedEvents(excluded), report.mapped_event_count, report.excluded_unmapped_count },
    );

    if (report.totals.len == 0) {
        std.debug.print("No mapped project events available for this range.\n", .{});
        return;
    }

    std.debug.print("{s:<45} {s:>12}\n", .{ "Project", "Time" });
    std.debug.print("{s:-<45} {s:->12}\n", .{ "", "" });
    for (report.totals) |total| {
        const name = ctx.queryRepo.getProjectName(total.project_id) catch null;
        defer if (name) |n| ctx.queryRepo.freeName(n);

        const label = if (name) |n| n else "(unknown project)";
        var dur_buf: [32]u8 = undefined;
        const duration = formatDuration(total.total_ms, &dur_buf);
        std.debug.print("{s:<45} {s:>12}\n", .{ label, duration });
    }

    std.debug.print("\nIntervals: {d}\n", .{report.intervals.len});
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

        if (rule.follow_previous) {
            maps_to = "(follow previous)";
        } else if (rule.is_global) {
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

    // Process all events in chronological order so follow_previous can reuse
    // the latest mapped activity/kind from earlier events.
    var result: c.duckdb_result = undefined;
    const query_sql =
        \\SELECT id, app_name, window_title, activity_id, kind_id, manually_mapped
        \\FROM events
        \\ORDER BY timestamp_ms ASC, id ASC
    ;

    if (c.duckdb_query(conn, query_sql, &result) == c.DuckDBError) {
        std.debug.print("Failed to query events\n", .{});
        return;
    }
    defer c.duckdb_destroy_result(&result);

    const row_count = c.duckdb_row_count(&result);
    const current_project_id = getCurrentProjectId(conn);
    var matched: u64 = 0;
    var unmapped: u64 = 0;
    var previous_mapping: ?ActivityKind = null;

    for (0..row_count) |i| {
        const row: c.idx_t = @intCast(i);
        const event_id = c.duckdb_value_int64(&result, 0, row);

        const has_mapping = !c.duckdb_value_is_null(&result, 3, row) and !c.duckdb_value_is_null(&result, 4, row);
        if (has_mapping) {
            previous_mapping = .{
                .activity_id = c.duckdb_value_int64(&result, 3, row),
                .kind_id = c.duckdb_value_int64(&result, 4, row),
            };
            continue;
        }

        const is_manually_mapped = c.duckdb_value_boolean(&result, 5, row);
        if (is_manually_mapped) continue;

        unmapped += 1;

        const app_name_ptr = c.duckdb_value_varchar(&result, 1, row);
        const title_ptr = c.duckdb_value_varchar(&result, 2, row);
        defer {
            if (app_name_ptr != null) c.duckdb_free(app_name_ptr);
            if (title_ptr != null) c.duckdb_free(title_ptr);
        }

        if (app_name_ptr == null or title_ptr == null) continue;

        const app_name = std.mem.span(app_name_ptr);
        const title = std.mem.span(title_ptr);

        const match = ctx.ruleRepo.findMatchWithContext(app_name, title, current_project_id) catch continue;
        if (match) |m| {
            const resolved_mapping: ?ActivityKind = switch (m.action) {
                .map_kind => if (m.activity_id != null and m.kind_id != null)
                    .{
                        .activity_id = m.activity_id.?,
                        .kind_id = m.kind_id.?,
                    }
                else
                    null,
                .follow_previous => previous_mapping,
            };

            if (resolved_mapping) |mapping| {
                if (updateEventMapping(conn, event_id, mapping)) {
                    previous_mapping = mapping;
                    matched += 1;
                }
            }
        }
    }

    std.debug.print("Applied rules to {d} events (out of {d} unmapped).\n", .{ matched, unmapped });
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
// CONFIG COMMAND
// =============================================================================

fn runConfig(allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    if (args.len < 1) {
        runConfigList(allocator);
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "list")) {
        runConfigList(allocator);
    } else if (std.mem.eql(u8, subcommand, "get")) {
        if (args.len < 2) {
            std.debug.print("Usage: tt config get <key>\n", .{});
            std.debug.print("Available keys: work-wifis, enabled, weighted-bucket-minutes, weighted-switch-minutes, noise-apps, noise-bucket-minutes, noise-switch-minutes\n", .{});
            return;
        }
        runConfigGet(allocator, args[1]);
    } else if (std.mem.eql(u8, subcommand, "set")) {
        if (args.len < 3) {
            std.debug.print("Usage: tt config set <key> <value>\n", .{});
            std.debug.print("Available keys: work-wifis, enabled, weighted-bucket-minutes, weighted-switch-minutes, noise-apps, noise-bucket-minutes, noise-switch-minutes\n", .{});
            return;
        }
        runConfigSet(allocator, args[1], args[2]);
    } else if (std.mem.eql(u8, subcommand, "unset")) {
        if (args.len < 2) {
            std.debug.print("Usage: tt config unset <key>\n", .{});
            std.debug.print("Available keys: work-wifis, enabled, weighted-bucket-minutes, weighted-switch-minutes, noise-apps, noise-bucket-minutes, noise-switch-minutes\n", .{});
            return;
        }
        runConfigUnset(allocator, args[1]);
    } else {
        std.debug.print("Unknown config subcommand: {s}\n", .{subcommand});
        std.debug.print("Usage: tt config <list|get|set|unset>\n", .{});
    }
}

fn runConfigList(allocator: std.mem.Allocator) void {
    const entries = config.listAll(allocator) catch |err| {
        std.debug.print("Failed to load config: {}\n", .{err});
        return;
    };
    defer config.freeEntries(allocator, entries);

    std.debug.print("\n=== Configuration ===\n\n", .{});

    for (entries) |entry| {
        const value_str = entry.value orelse "(not set)";
        std.debug.print("  {s}: {s}\n", .{ entry.key, value_str });
        std.debug.print("    {s}\n\n", .{entry.description});
    }

    const path = config.getConfigPath(allocator) catch {
        return;
    };
    defer allocator.free(path);
    std.debug.print("Config file: {s}\n\n", .{path});
}

fn runConfigGet(allocator: std.mem.Allocator, key: [:0]const u8) void {
    const value = config.getValue(allocator, key) catch |err| {
        std.debug.print("Failed to load config: {}\n", .{err});
        return;
    };

    if (value) |v| {
        defer allocator.free(v);
        std.debug.print("{s}\n", .{v});
    } else {
        std.debug.print("(not set)\n", .{});
    }
}

fn runConfigSet(allocator: std.mem.Allocator, key: [:0]const u8, value: [:0]const u8) void {
    config.setValue(allocator, key, value) catch |err| {
        std.debug.print("Failed to set config: {}\n", .{err});
        return;
    };

    std.debug.print("Set {s} = {s}\n", .{ key, value });
}

fn runConfigUnset(allocator: std.mem.Allocator, key: [:0]const u8) void {
    config.unsetValue(allocator, key) catch |err| {
        std.debug.print("Failed to unset config: {}\n", .{err});
        return;
    };

    std.debug.print("Unset {s} (returned to default)\n", .{key});
}

// =============================================================================
// WIFI COMMAND
// =============================================================================

fn runWifi(allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    if (args.len < 1) {
        runWifiList(allocator);
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "list")) {
        runWifiList(allocator);
    } else if (std.mem.eql(u8, subcommand, "add")) {
        if (args.len < 2) {
            // No pattern provided - use current WiFi
            runWifiAddCurrent(allocator);
        } else {
            runWifiAdd(allocator, args[1]);
        }
    } else if (std.mem.eql(u8, subcommand, "remove")) {
        if (args.len < 2) {
            std.debug.print("Usage: tt wifi remove <pattern>\n", .{});
            return;
        }
        runWifiRemove(allocator, args[1]);
    } else {
        std.debug.print("Unknown wifi subcommand: {s}\n", .{subcommand});
        std.debug.print("Usage: tt wifi <list|add|remove>\n", .{});
    }
}

fn runWifiList(allocator: std.mem.Allocator) void {
    const wifis = config.getWorkWifis(allocator) catch |err| {
        std.debug.print("Failed to load config: {}\n", .{err});
        return;
    };
    defer config.freeWorkWifis(allocator, wifis);

    std.debug.print("\n=== Work WiFi Patterns ===\n\n", .{});

    if (wifis.len == 0) {
        std.debug.print("  (none configured - tracking on all networks)\n", .{});
    } else {
        for (wifis, 1..) |pattern, i| {
            std.debug.print("  {d}. {s}\n", .{ i, pattern });
        }
    }

    // Show current WiFi
    if (get_wifi_ssid()) |ssid| {
        const current_ssid = std.mem.span(ssid);
        std.debug.print("\nCurrent WiFi: {s}\n", .{current_ssid});
    } else {
        std.debug.print("\nCurrent WiFi: (not connected or unknown)\n", .{});
    }

    std.debug.print("\n", .{});
}

fn runWifiAddCurrent(allocator: std.mem.Allocator) void {
    const ssid_ptr = get_wifi_ssid();
    if (ssid_ptr == null) {
        std.debug.print("Could not detect current WiFi network.\n", .{});
        std.debug.print("Usage: tt wifi add <pattern>\n", .{});
        return;
    }

    const ssid = std.mem.span(ssid_ptr.?);
    config.addWorkWifi(allocator, ssid) catch |err| {
        std.debug.print("Failed to add WiFi: {}\n", .{err});
        return;
    };

    std.debug.print("Added work WiFi: {s}\n", .{ssid});
}

fn runWifiAdd(allocator: std.mem.Allocator, pattern: [:0]const u8) void {
    config.addWorkWifi(allocator, pattern) catch |err| {
        std.debug.print("Failed to add WiFi pattern: {}\n", .{err});
        return;
    };

    std.debug.print("Added work WiFi pattern: {s}\n", .{pattern});
}

fn runWifiRemove(allocator: std.mem.Allocator, pattern: [:0]const u8) void {
    const removed = config.removeWorkWifi(allocator, pattern) catch |err| {
        std.debug.print("Failed to remove WiFi pattern: {}\n", .{err});
        return;
    };

    if (removed) {
        std.debug.print("Removed work WiFi pattern: {s}\n", .{pattern});
    } else {
        std.debug.print("Pattern not found: {s}\n", .{pattern});
    }
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

const ActivityKind = struct {
    activity_id: i64,
    kind_id: i64,
};

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

fn updateEventMapping(conn: c.duckdb_connection, event_id: i64, mapping: ActivityKind) bool {
    var update_stmt: c.duckdb_prepared_statement = undefined;
    const update_sql = "UPDATE events SET activity_id = ?, kind_id = ? WHERE id = ?";

    if (c.duckdb_prepare(conn, update_sql, &update_stmt) == c.DuckDBError) return false;
    defer c.duckdb_destroy_prepare(&update_stmt);

    _ = c.duckdb_bind_int64(update_stmt, 1, mapping.activity_id);
    _ = c.duckdb_bind_int64(update_stmt, 2, mapping.kind_id);
    _ = c.duckdb_bind_int64(update_stmt, 3, event_id);

    var update_result: c.duckdb_result = undefined;
    if (c.duckdb_execute_prepared(update_stmt, &update_result) == c.DuckDBError) {
        c.duckdb_destroy_result(&update_result);
        return false;
    }
    c.duckdb_destroy_result(&update_result);
    return true;
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

    const current_project_id = getCurrentProjectId(conn);

    // Create rule repository and look for a match
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

        // Get project and activity names
        var hierarchy_repo_impl = DuckDbHierarchyRepository.init(conn, allocator);
        const names = hierarchy_repo_impl.getProjectAndActivityForKind(resolved_kind_id) catch {
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

var global_daemon_db_path_buf: [640]u8 = undefined;

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

    // Create directory if it doesn't exist
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

    // Load configuration
    var cfg = config.load(allocator) catch |err| {
        std.debug.print("Warning: Failed to load config: {}. Using defaults.\n", .{err});
        // Continue with defaults instead of returning
        runDaemonWithDefaults(allocator);
        return;
    };
    defer cfg.deinit(allocator);

    // Configure WiFi-based tracking
    if (cfg.work_wifis.len > 0) {
        std.debug.print("Work WiFi patterns: ", .{});
        for (cfg.work_wifis, 0..) |pattern, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{pattern});
            // Null-terminate for C interop
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
    defer global_tracker = null;

    // Check accessibility
    if (!check_accessibility()) {
        std.debug.print("\nWarning: Accessibility not yet granted. Will report error on start.\n", .{});
    }

    std.debug.print("\nStarting event listener... (switch windows to see events)\n", .{});
    std.debug.print("Press Ctrl+C to exit.\n\n", .{});

    // Hand control to Swift's NSRunLoop (blocks forever)
    start_listening(&onEvent);
}
