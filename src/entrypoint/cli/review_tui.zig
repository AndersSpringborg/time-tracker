//! Review TUI - Interactive event review with libvaxis
//!
//! A modern TUI for reviewing and mapping time tracking events.
//! Supports multi-select, bulk mapping, and day-based navigation.

const std = @import("std");
const vaxis = @import("vaxis");
const review = @import("review");
const migrations = @import("migrations");
const c = migrations.c;

const Reviewer = review.Reviewer;
const UnmappedEvent = review.UnmappedEvent;
const DateString = review.DateString;

/// Event row for table display
const EventRow = struct {
    id: i64,
    app_name: []const u8,
    window_title: []const u8,
    duration: []const u8,

    // Storage buffers
    app_buf: [256]u8 = undefined,
    title_buf: [512]u8 = undefined,
    duration_buf: [32]u8 = undefined,
};

/// Application state
const App = struct {
    allocator: std.mem.Allocator,
    reviewer: Reviewer,
    events: []UnmappedEvent,
    rows: []EventRow,
    table_ctx: vaxis.widgets.Table.TableContext,
    should_quit: bool = false,

    // Day navigation
    dates: []DateString,
    current_date_idx: usize = 0,

    pub fn init(allocator: std.mem.Allocator, conn: c.duckdb_connection) !App {
        var reviewer_instance = Reviewer.init(conn, allocator);

        // Get all dates with unmapped events
        const dates = try reviewer_instance.getDatesWithUnmappedEvents();

        if (dates.len == 0) {
            allocator.free(dates);
            return error.NoEvents;
        }

        // Fetch events for the first (most recent) date
        const events = try reviewer_instance.getUnmappedEventsForDate(dates[0].slice());
        const rows = try convertToRows(allocator, events);

        return App{
            .allocator = allocator,
            .reviewer = reviewer_instance,
            .events = events,
            .rows = rows,
            .dates = dates,
            .current_date_idx = 0,
            .table_ctx = .{
                .active = true,
                .active_bg = .{ .rgb = .{ 64, 128, 255 } },
                .selected_bg = .{ .rgb = .{ 32, 64, 255 } },
                .row_bg_1 = .{ .rgb = .{ 24, 24, 24 } },
                .row_bg_2 = .{ .rgb = .{ 16, 16, 16 } },
                .header_names = .{ .custom = &.{ "App", "Window Title", "Duration" } },
                .col_indexes = .{ .by_idx = &.{ 1, 2, 3 } }, // Skip id field
                .col_width = .{ .static_individual = &.{ 20, 50, 12 } },
            },
        };
    }

    pub fn deinit(self: *App) void {
        self.allocator.free(self.rows);
        self.allocator.free(self.events);
        self.allocator.free(self.dates);
        if (self.table_ctx.sel_rows) |sel| {
            self.allocator.free(sel);
        }
    }

    /// Reload events for the current date
    fn reloadEvents(self: *App) !void {
        // Free old data
        self.allocator.free(self.rows);
        self.allocator.free(self.events);
        if (self.table_ctx.sel_rows) |sel| {
            self.allocator.free(sel);
            self.table_ctx.sel_rows = null;
        }

        // Load new events
        const date = self.dates[self.current_date_idx].slice();
        self.events = try self.reviewer.getUnmappedEventsForDate(date);
        self.rows = try convertToRows(self.allocator, self.events);

        // Reset cursor
        self.table_ctx.row = 0;
    }

    /// Navigate to the previous day (older)
    fn prevDay(self: *App) void {
        if (self.current_date_idx + 1 < self.dates.len) {
            self.current_date_idx += 1;
            self.reloadEvents() catch {};
        }
    }

    /// Navigate to the next day (newer)
    fn nextDay(self: *App) void {
        if (self.current_date_idx > 0) {
            self.current_date_idx -= 1;
            self.reloadEvents() catch {};
        }
    }

    pub fn getCurrentDate(self: *App) []const u8 {
        return self.dates[self.current_date_idx].slice();
    }

    pub fn handleKey(self: *App, key: vaxis.Key) bool {
        // Quit
        if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
            self.should_quit = true;
            return true;
        }

        // Day navigation
        if (key.matches('[', .{})) {
            self.prevDay();
            return false;
        }
        if (key.matches(']', .{})) {
            self.nextDay();
            return false;
        }

        // Navigation
        if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) {
            self.table_ctx.row -|= 1;
        }
        if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) {
            if (self.table_ctx.row < self.rows.len -| 1) {
                self.table_ctx.row +|= 1;
            }
        }

        // Page navigation
        if (key.matches('d', .{ .ctrl = true })) {
            self.table_ctx.row +|= 20;
            if (self.table_ctx.row >= self.rows.len) {
                self.table_ctx.row = @intCast(self.rows.len -| 1);
            }
        }
        if (key.matches('u', .{ .ctrl = true })) {
            self.table_ctx.row -|= 20;
        }

        // Go to top/bottom
        if (key.matches('g', .{})) {
            self.table_ctx.row = 0;
        }
        if (key.matches('G', .{})) {
            if (self.rows.len > 0) {
                self.table_ctx.row = @intCast(self.rows.len - 1);
            }
        }

        // Selection with Space
        if (key.matches(vaxis.Key.space, .{})) {
            self.toggleSelection(self.table_ctx.row);
        }

        // Select all with same app
        if (key.matches('a', .{})) {
            self.selectByApp();
        }

        // Clear selection
        if (key.matches(vaxis.Key.escape, .{})) {
            if (self.table_ctx.sel_rows) |sel| {
                self.allocator.free(sel);
                self.table_ctx.sel_rows = null;
            }
        }

        return false;
    }

    fn toggleSelection(self: *App, row: u16) void {
        if (self.table_ctx.sel_rows) |sel| {
            // Check if already selected - if so, remove it
            for (sel) |r| {
                if (r == row) {
                    // Remove from selection by creating new array without this element
                    if (sel.len == 1) {
                        self.allocator.free(sel);
                        self.table_ctx.sel_rows = null;
                    } else {
                        const new_sel = self.allocator.alloc(u16, sel.len - 1) catch return;
                        var j: usize = 0;
                        for (sel) |s| {
                            if (s != row) {
                                new_sel[j] = s;
                                j += 1;
                            }
                        }
                        self.allocator.free(sel);
                        self.table_ctx.sel_rows = new_sel;
                    }
                    return;
                }
            }

            // Not found - add to selection
            const new_sel = self.allocator.alloc(u16, sel.len + 1) catch return;
            @memcpy(new_sel[0..sel.len], sel);
            new_sel[sel.len] = row;
            self.allocator.free(sel);
            self.table_ctx.sel_rows = new_sel;
        } else {
            // Create new selection
            const new_sel = self.allocator.alloc(u16, 1) catch return;
            new_sel[0] = row;
            self.table_ctx.sel_rows = new_sel;
        }
    }

    fn selectByApp(self: *App) void {
        if (self.rows.len == 0) return;

        const current_row = self.table_ctx.row;
        if (current_row >= self.rows.len) return;

        const current_app = self.rows[current_row].app_name;

        // Count matching rows
        var count: usize = 0;
        for (self.rows) |row| {
            if (std.mem.eql(u8, row.app_name, current_app)) {
                count += 1;
            }
        }

        // Allocate selection
        const new_sel = self.allocator.alloc(u16, count) catch return;
        var idx: usize = 0;
        for (self.rows, 0..) |row, i| {
            if (std.mem.eql(u8, row.app_name, current_app)) {
                new_sel[idx] = @intCast(i);
                idx += 1;
            }
        }

        // Free old selection if exists
        if (self.table_ctx.sel_rows) |old| {
            self.allocator.free(old);
        }
        self.table_ctx.sel_rows = new_sel;
    }

    pub fn getSelectionCount(self: *App) usize {
        if (self.table_ctx.sel_rows) |sel| {
            return sel.len;
        }
        return 0;
    }
};

fn convertToRows(allocator: std.mem.Allocator, events: []UnmappedEvent) ![]EventRow {
    const rows = try allocator.alloc(EventRow, events.len);
    for (events, 0..) |event, i| {
        rows[i] = EventRow{
            .id = event.id,
            .app_name = undefined,
            .window_title = undefined,
            .duration = undefined,
        };

        // Copy app name
        const app_len = @min(event.app_name.len, 255);
        @memcpy(rows[i].app_buf[0..app_len], event.app_name[0..app_len]);
        rows[i].app_name = rows[i].app_buf[0..app_len];

        // Copy and truncate window title
        const title_len = @min(event.window_title.len, 60);
        @memcpy(rows[i].title_buf[0..title_len], event.window_title[0..title_len]);
        rows[i].window_title = rows[i].title_buf[0..title_len];

        // Format duration
        const duration_str = formatDuration(event.duration_ms, &rows[i].duration_buf);
        rows[i].duration = duration_str;
    }
    return rows;
}

fn formatDuration(ms: i64, buf: []u8) []const u8 {
    const total_seconds = @divFloor(ms, 1000);
    const hours = @divFloor(total_seconds, 3600);
    const minutes = @divFloor(@mod(total_seconds, 3600), 60);
    const seconds = @mod(total_seconds, 60);

    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}h {d}m", .{ hours, minutes }) catch "?";
    } else if (minutes > 0) {
        return std.fmt.bufPrint(buf, "{d}m {d}s", .{ minutes, seconds }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d}s", .{seconds}) catch "?";
    }
}

/// Run the review TUI
pub fn run(allocator: std.mem.Allocator, conn: c.duckdb_connection) !void {
    // Initialize vaxis
    var tty_buf: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.writer());

    // Initialize app
    var app = App.init(allocator, conn) catch |err| {
        if (err == error.NoEvents) {
            std.debug.print("No unmapped events to review.\n", .{});
            return;
        }
        return err;
    };
    defer app.deinit();

    // Event loop
    var loop: vaxis.Loop(union(enum) {
        key_press: vaxis.Key,
        winsize: vaxis.Winsize,
    }) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), 250 * std.time.ns_per_ms);

    while (!app.should_quit) {
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                _ = app.handleKey(key);
            },
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
        }

        // Render
        const win = vx.window();
        win.clear();

        // Header
        const header_win = win.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = win.width,
            .height = 2,
        });
        header_win.fill(.{ .style = .{ .bg = .{ .rgb = .{ 32, 32, 48 } } } });

        var header_buf: [256]u8 = undefined;
        const sel_count = app.getSelectionCount();
        const current_date = app.getCurrentDate();
        const date_info_len = app.dates.len;
        const date_pos = app.current_date_idx + 1;
        const header_text = std.fmt.bufPrint(&header_buf, " {s} ({d}/{d}) | {d} events | {d} selected | [/]:Day j/k:Move Space:Select a:App q:Quit", .{ current_date, date_pos, date_info_len, app.rows.len, sel_count }) catch "Review";
        _ = header_win.print(&.{.{ .text = header_text, .style = .{ .fg = .{ .rgb = .{ 200, 200, 200 } } } }}, .{});

        // Table
        const table_win = win.child(.{
            .x_off = 0,
            .y_off = 2,
            .width = win.width,
            .height = win.height -| 2,
        });

        if (app.rows.len > 0) {
            try vaxis.widgets.Table.drawTable(
                null,
                table_win,
                app.rows,
                &app.table_ctx,
            );
        } else {
            // Show message when no events for current day
            _ = table_win.print(&.{.{ .text = "  No events for this date", .style = .{ .fg = .{ .rgb = .{ 128, 128, 128 } } } }}, .{});
        }

        try vx.render(tty.writer());
    }
}
