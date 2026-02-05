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
const HierarchyMatch = review.HierarchyMatch;

/// Event row for table display
/// Fields are ordered so display columns (app, title, duration) come first
const EventRow = struct {
    // Display fields (indices 0, 1, 2)
    app_name: []const u8,
    window_title: []const u8,
    duration: []const u8,

    // Non-display fields
    id: i64,

    // Storage buffers
    app_buf: [256]u8 = undefined,
    title_buf: [512]u8 = undefined,
    duration_buf: [32]u8 = undefined,
};

/// UI Mode
const Mode = enum {
    normal,
    search,
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

    // Modal state
    mode: Mode = .normal,
    search_buf: [128]u8 = undefined,
    search_len: usize = 0,
    search_results: []HierarchyMatch = &[_]HierarchyMatch{},
    search_cursor: usize = 0,

    // Status message
    status_msg: []const u8 = "",
    status_is_error: bool = false,

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
                .col_indexes = .{ .by_idx = &.{ 0, 1, 2 } }, // app_name, window_title, duration
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
        self.freeSearchResults();
    }

    fn freeSearchResults(self: *App) void {
        for (self.search_results) |match| {
            self.allocator.free(match.display_path);
        }
        if (self.search_results.len > 0) {
            self.allocator.free(self.search_results);
            self.search_results = &[_]HierarchyMatch{};
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

    /// Reload dates list (after mapping/discarding events)
    fn reloadDates(self: *App) !void {
        self.allocator.free(self.dates);
        self.dates = try self.reviewer.getDatesWithUnmappedEvents();

        if (self.dates.len == 0) {
            // No more events, will quit
            self.should_quit = true;
            self.status_msg = "All events processed!";
            return;
        }

        // Adjust current date index if needed
        if (self.current_date_idx >= self.dates.len) {
            self.current_date_idx = self.dates.len - 1;
        }
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
        if (self.dates.len == 0) return "N/A";
        return self.dates[self.current_date_idx].slice();
    }

    /// Get selected event IDs (or current row if nothing selected)
    fn getSelectedEventIds(self: *App) ![]i64 {
        if (self.table_ctx.sel_rows) |sel| {
            const ids = try self.allocator.alloc(i64, sel.len);
            for (sel, 0..) |row_idx, i| {
                if (row_idx < self.events.len) {
                    ids[i] = self.events[row_idx].id;
                }
            }
            return ids;
        } else {
            // Use current row
            const ids = try self.allocator.alloc(i64, 1);
            if (self.table_ctx.row < self.events.len) {
                ids[0] = self.events[self.table_ctx.row].id;
            }
            return ids;
        }
    }

    /// Perform mapping of selected events
    fn performMapping(self: *App, match: HierarchyMatch) void {
        const event_ids = self.getSelectedEventIds() catch {
            self.status_msg = "Error getting selection";
            self.status_is_error = true;
            return;
        };
        defer self.allocator.free(event_ids);

        self.reviewer.mapEvents(event_ids, match.activity_id, match.kind_id) catch {
            self.status_msg = "Error mapping events";
            self.status_is_error = true;
            return;
        };

        // Clear search state
        self.mode = .normal;
        self.search_len = 0;
        self.freeSearchResults();
        self.search_cursor = 0;

        // Reload data
        self.reloadDates() catch {};
        if (!self.should_quit) {
            self.reloadEvents() catch {};
        }

        self.status_msg = "Events mapped successfully";
        self.status_is_error = false;
    }

    /// Discard selected events
    fn discardSelected(self: *App) void {
        const event_ids = self.getSelectedEventIds() catch {
            self.status_msg = "Error getting selection";
            self.status_is_error = true;
            return;
        };
        defer self.allocator.free(event_ids);

        self.reviewer.discardEvents(event_ids) catch {
            self.status_msg = "Error discarding events";
            self.status_is_error = true;
            return;
        };

        // Reload data
        self.reloadDates() catch {};
        if (!self.should_quit) {
            self.reloadEvents() catch {};
        }

        self.status_msg = "Events discarded";
        self.status_is_error = false;
    }

    /// Perform search
    fn doSearch(self: *App) void {
        self.freeSearchResults();
        self.search_cursor = 0;

        if (self.search_len == 0) return;

        self.search_results = self.reviewer.searchFullHierarchy(self.search_buf[0..self.search_len]) catch {
            self.status_msg = "Search failed";
            self.status_is_error = true;
            return;
        };
    }

    pub fn handleKey(self: *App, key: vaxis.Key) bool {
        // Mode-specific handling
        switch (self.mode) {
            .search => return self.handleSearchKey(key),
            .normal => return self.handleNormalKey(key),
        }
    }

    fn handleSearchKey(self: *App, key: vaxis.Key) bool {
        // Cancel search
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
            self.mode = .normal;
            self.search_len = 0;
            self.freeSearchResults();
            return false;
        }

        // Confirm selection
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.search_results.len > 0 and self.search_cursor < self.search_results.len) {
                self.performMapping(self.search_results[self.search_cursor]);
            }
            return false;
        }

        // Navigate results
        if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{ .ctrl = true })) {
            if (self.search_cursor > 0) {
                self.search_cursor -= 1;
            }
            return false;
        }
        if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{ .ctrl = true })) {
            if (self.search_cursor + 1 < self.search_results.len) {
                self.search_cursor += 1;
            }
            return false;
        }

        // Backspace
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.search_len > 0) {
                self.search_len -= 1;
                self.doSearch();
            }
            return false;
        }

        // Type character
        if (key.text) |text| {
            if (self.search_len + text.len <= self.search_buf.len) {
                @memcpy(self.search_buf[self.search_len .. self.search_len + text.len], text);
                self.search_len += text.len;
                self.doSearch();
            }
            return false;
        }

        return false;
    }

    fn handleNormalKey(self: *App, key: vaxis.Key) bool {
        // Quit
        if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
            self.should_quit = true;
            return true;
        }

        // Open search/map modal
        if (key.matches('m', .{})) {
            if (self.rows.len > 0) {
                self.mode = .search;
                self.search_len = 0;
                self.freeSearchResults();
            }
            return false;
        }

        // Discard selected events
        if (key.matches('d', .{})) {
            if (self.rows.len > 0) {
                self.discardSelected();
            }
            return false;
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
            self.status_msg = "";
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
        const header_text = std.fmt.bufPrint(&header_buf, " {s} ({d}/{d}) | {d} events | {d} sel | []:Day Space:Sel a:App m:Map d:Discard q:Quit", .{ current_date, date_pos, date_info_len, app.rows.len, sel_count }) catch "Review";
        _ = header_win.print(&.{.{ .text = header_text, .style = .{ .fg = .{ .rgb = .{ 200, 200, 200 } } } }}, .{});

        // Status message on line 2 if present
        if (app.status_msg.len > 0) {
            const status_color: vaxis.Color = if (app.status_is_error) .{ .rgb = .{ 255, 100, 100 } } else .{ .rgb = .{ 100, 255, 100 } };
            _ = header_win.print(&.{ .{ .text = " ", .style = .{} }, .{ .text = app.status_msg, .style = .{ .fg = status_color } } }, .{ .row_offset = 1 });
        }

        // Table area
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
            _ = table_win.print(&.{.{ .text = "  No events for this date", .style = .{ .fg = .{ .rgb = .{ 128, 128, 128 } } } }}, .{});
        }

        // Search modal overlay
        if (app.mode == .search) {
            const modal_width: u16 = @min(80, win.width -| 4);
            const modal_height: u16 = @min(15, win.height -| 4);
            const modal_x = (win.width -| modal_width) / 2;
            const modal_y = (win.height -| modal_height) / 2;

            const modal_win = win.child(.{
                .x_off = modal_x,
                .y_off = modal_y,
                .width = modal_width,
                .height = modal_height,
            });

            // Modal background
            modal_win.fill(.{ .style = .{ .bg = .{ .rgb = .{ 40, 40, 50 } } } });

            // Border (simple)
            for (0..modal_width) |x| {
                modal_win.writeCell(@intCast(x), 0, .{ .char = .{ .grapheme = "-" }, .style = .{ .fg = .{ .rgb = .{ 100, 100, 120 } } } });
                modal_win.writeCell(@intCast(x), modal_height -| 1, .{ .char = .{ .grapheme = "-" }, .style = .{ .fg = .{ .rgb = .{ 100, 100, 120 } } } });
            }

            // Title
            _ = modal_win.print(&.{.{ .text = " Search & Map (Esc to cancel, Enter to confirm)", .style = .{ .fg = .{ .rgb = .{ 200, 200, 200 } } } }}, .{ .row_offset = 1 });

            // Search input
            var search_display: [140]u8 = undefined;
            const search_text = std.fmt.bufPrint(&search_display, " > {s}_", .{app.search_buf[0..app.search_len]}) catch " > _";
            _ = modal_win.print(&.{.{ .text = search_text, .style = .{ .fg = .{ .rgb = .{ 255, 255, 100 } } } }}, .{ .row_offset = 3 });

            // Results
            if (app.search_results.len > 0) {
                var result_row: u16 = 5;
                for (app.search_results, 0..) |match, i| {
                    if (result_row >= modal_height - 1) break;

                    const is_selected = i == app.search_cursor;
                    const fg_color: vaxis.Color = if (is_selected) .{ .rgb = .{ 255, 255, 255 } } else .{ .rgb = .{ 180, 180, 180 } };
                    const bg_color: vaxis.Color = if (is_selected) .{ .rgb = .{ 60, 80, 120 } } else .{ .rgb = .{ 40, 40, 50 } };

                    // Truncate path to fit
                    const max_path_len = @min(match.display_path.len, modal_width - 4);
                    const path_slice = match.display_path[0..max_path_len];

                    var line_buf: [100]u8 = undefined;
                    const line_text = std.fmt.bufPrint(&line_buf, "  {s}", .{path_slice}) catch "  ...";

                    // Fill row background
                    for (1..modal_width - 1) |x| {
                        modal_win.writeCell(@intCast(x), result_row, .{ .char = .{ .grapheme = " " }, .style = .{ .bg = bg_color } });
                    }

                    _ = modal_win.print(&.{.{ .text = line_text, .style = .{ .fg = fg_color, .bg = bg_color } }}, .{ .row_offset = result_row, .col_offset = 0 });
                    result_row += 1;
                }
            } else if (app.search_len > 0) {
                _ = modal_win.print(&.{.{ .text = "  No matches found", .style = .{ .fg = .{ .rgb = .{ 128, 128, 128 } } } }}, .{ .row_offset = 5 });
            } else {
                _ = modal_win.print(&.{.{ .text = "  Type to search hierarchy...", .style = .{ .fg = .{ .rgb = .{ 128, 128, 128 } } } }}, .{ .row_offset = 5 });
            }

            // Navigation hint
            _ = modal_win.print(&.{.{ .text = " Ctrl+j/k: Navigate results", .style = .{ .fg = .{ .rgb = .{ 100, 100, 100 } } } }}, .{ .row_offset = modal_height -| 2 });
        }

        try vx.render(tty.writer());
    }
}
