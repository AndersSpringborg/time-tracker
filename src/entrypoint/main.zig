//! CLI Entry Point using Clean Architecture
//!
//! This is the new entry point that uses AppContext to wire up all dependencies.
//! Commands delegate to use cases and repositories via the composition root.

const std = @import("std");
const AppContext = @import("app_context").AppContext;

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
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{command});
        printUsage();
    }
}

fn printUsage() void {
    const usage =
        \\Usage: time_tracker <command> [options]
        \\
        \\Commands:
        \\  summary        Show time spent per application
        \\  report         Show detailed report with window titles
        \\  import         Import customer hierarchy from JSON file
        \\  help           Show this help message
        \\
        \\Options for summary/report:
        \\  --today        Show only today's data (default)
        \\  --week         Show last 7 days
        \\  --all          Show all time
        \\
        \\Examples:
        \\  time_tracker summary --today
        \\  time_tracker report --week
        \\  time_tracker import customers.json
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

    // Convert our TimeRange to query repository's TimeRange
    const query_range = switch (range) {
        .today => @import("query_repository").TimeRange.today,
        .week => @import("query_repository").TimeRange.week,
        .all => @import("query_repository").TimeRange.all,
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
        .today => @import("query_repository").TimeRange.today,
        .week => @import("query_repository").TimeRange.week,
        .all => @import("query_repository").TimeRange.all,
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

fn runImport(allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    if (args.len < 1) {
        std.debug.print("Usage: time_tracker import <customers.json>\n", .{});
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
