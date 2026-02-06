//! Review TUI - Interactive event review with libvaxis
//!
//! A modern TUI for reviewing and mapping time tracking events.
//! Supports multi-select, bulk mapping, and day-based navigation.

const std = @import("std");
const vaxis = @import("vaxis");
const review = @import("review");
const review_mode_usecase = @import("review_mode_usecase");
const migrations = @import("migrations");
const c = migrations.c;

const Reviewer = review.Reviewer;
const GroupedEvent = review.GroupedEvent;
const DateString = review.DateString;
const HourBucket = review.HourBucket;
const HierarchyMatch = review.HierarchyMatch;
const RuleSuggestion = review.RuleSuggestion;
const UnmappedEvent = review.UnmappedEvent;
const ReviewModeUseCase = review_mode_usecase.ReviewModeUseCase;

/// Event row for table display (grouped events)
/// Fields are ordered so display columns (app, title, count, duration) come first
const EventRow = struct {
    // Display fields (indices 0, 1, 2, 3)
    app_name: []const u8,
    window_title: []const u8,
    count: []const u8,
    duration: []const u8,

    // Storage buffers
    app_buf: [256]u8 = undefined,
    title_buf: [512]u8 = undefined,
    count_buf: [16]u8 = undefined,
    duration_buf: [32]u8 = undefined,
};

/// Timeline row for stable, fixed-width rendering
const TimelineRow = struct {
    time_text: []const u8,
    app_name: []const u8,
    window_title: []const u8,
    duration: []const u8,
    hour: u8,

    time_buf: [16]u8 = undefined,
    app_buf: [256]u8 = undefined,
    title_buf: [512]u8 = undefined,
    duration_buf: [20]u8 = undefined,
};

/// UI Mode
const Mode = enum {
    normal,
    search,
    rule_menu, // Choosing rule type (app-only vs app+title)
    analyze, // Showing suggestions in split view
    accept_dialog, // Confirming suggestion acceptance
};

const ViewMode = enum {
    grouped,
    timeline,
};

const HourStats = struct {
    event_count: i64 = 0,
    total_duration_ms: i64 = 0,
};

const Selection = struct {
    app_name: []const u8,
    window_title: []const u8,
};

/// Application state
const App = struct {
    allocator: std.mem.Allocator,
    usecase: ReviewModeUseCase,
    groups: []GroupedEvent,
    rows: []EventRow,
    timeline_events: []UnmappedEvent,
    timeline_rows: []TimelineRow,
    timeline_cursor: usize = 0,
    hour_stats: [24]HourStats = [_]HourStats{.{}} ** 24,
    view_mode: ViewMode = .grouped,
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
    status_buf: [128]u8 = undefined, // Buffer for dynamic status messages

    // Analyze mode state
    suggestions: []RuleSuggestion = &[_]RuleSuggestion{},
    suggestion_cursor: usize = 0,

    pub fn init(allocator: std.mem.Allocator, conn: c.duckdb_connection) !App {
        const reviewer_instance = Reviewer.init(conn, allocator);
        var usecase = ReviewModeUseCase.init(reviewer_instance);

        // Get all dates with unmapped events through the use case filter policy.
        const dates = try usecase.getDatesWithUnmappedEvents();

        if (dates.len == 0) {
            allocator.free(dates);
            return error.NoEvents;
        }

        const current_date = dates[0].slice();
        const groups = try usecase.getGroupedEventsForDate(current_date);
        const rows = try convertToRows(allocator, groups);
        const timeline_events = try usecase.getTimelineEventsForDate(current_date);
        const timeline_rows = try convertToTimelineRows(allocator, timeline_events);

        var hour_stats: [24]HourStats = [_]HourStats{.{}} ** 24;
        const hour_buckets = try usecase.getHourlySummaryForDate(current_date);
        defer allocator.free(hour_buckets);
        fillHourStats(&hour_stats, hour_buckets);

        return App{
            .allocator = allocator,
            .usecase = usecase,
            .groups = groups,
            .rows = rows,
            .timeline_events = timeline_events,
            .timeline_rows = timeline_rows,
            .hour_stats = hour_stats,
            .dates = dates,
            .current_date_idx = 0,
            .table_ctx = .{
                .active = true,
                .active_bg = .{ .rgb = .{ 64, 128, 255 } },
                .selected_bg = .{ .rgb = .{ 32, 64, 255 } },
                .row_bg_1 = .{ .rgb = .{ 24, 24, 24 } },
                .row_bg_2 = .{ .rgb = .{ 16, 16, 16 } },
                .header_names = .{ .custom = &.{ "App", "Window Title", "Count", "Duration" } },
                .col_indexes = .{ .by_idx = &.{ 0, 1, 2, 3 } }, // app_name, window_title, count, duration
                .col_width = .{ .static_individual = &.{ 20, 45, 8, 12 } },
            },
        };
    }

    pub fn deinit(self: *App) void {
        self.allocator.free(self.rows);
        self.allocator.free(self.groups);
        self.allocator.free(self.timeline_events);
        self.allocator.free(self.timeline_rows);
        self.allocator.free(self.dates);
        self.freeSearchResults();
        self.freeSuggestions();
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

    fn freeSuggestions(self: *App) void {
        if (self.suggestions.len > 0) {
            self.allocator.free(self.suggestions);
            self.suggestions = &[_]RuleSuggestion{};
        }
    }

    /// Reload events for the current date
    fn reloadEvents(self: *App) !void {
        // Free old data
        self.allocator.free(self.rows);
        self.allocator.free(self.groups);
        self.allocator.free(self.timeline_events);
        self.allocator.free(self.timeline_rows);

        if (self.dates.len == 0) {
            self.rows = try self.allocator.alloc(EventRow, 0);
            self.groups = try self.allocator.alloc(GroupedEvent, 0);
            self.timeline_events = try self.allocator.alloc(UnmappedEvent, 0);
            self.timeline_rows = try self.allocator.alloc(TimelineRow, 0);
            self.table_ctx.row = 0;
            self.timeline_cursor = 0;
            self.hour_stats = [_]HourStats{.{}} ** 24;
            return;
        }

        const date = self.dates[self.current_date_idx].slice();
        self.groups = try self.usecase.getGroupedEventsForDate(date);
        self.rows = try convertToRows(self.allocator, self.groups);
        self.timeline_events = try self.usecase.getTimelineEventsForDate(date);
        self.timeline_rows = try convertToTimelineRows(self.allocator, self.timeline_events);

        self.hour_stats = [_]HourStats{.{}} ** 24;
        const hour_buckets = try self.usecase.getHourlySummaryForDate(date);
        defer self.allocator.free(hour_buckets);
        fillHourStats(&self.hour_stats, hour_buckets);

        if (self.table_ctx.row >= self.rows.len) {
            self.table_ctx.row = @intCast(self.rows.len -| 1);
        }
        if (self.timeline_cursor >= self.timeline_rows.len) {
            self.timeline_cursor = self.timeline_rows.len -| 1;
        }
    }

    /// Reload dates list (after mapping/discarding events)
    fn reloadDates(self: *App) !void {
        self.allocator.free(self.dates);
        self.dates = try self.usecase.getDatesWithUnmappedEvents();

        if (self.dates.len == 0) {
            if (self.usecase.isShortEventFilterEnabled()) {
                self.should_quit = false;
                self.status_msg = "No events >=2s (press f to show all)";
                self.status_is_error = false;
            } else {
                self.should_quit = true;
                self.status_msg = "All events processed!";
                self.status_is_error = false;
            }
            self.current_date_idx = 0;
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

    /// Get the current group (row under cursor)
    fn getCurrentGroup(self: *App) ?*GroupedEvent {
        if (self.table_ctx.row >= self.groups.len) return null;
        return &self.groups[self.table_ctx.row];
    }

    fn getCurrentTimelineEvent(self: *App) ?*UnmappedEvent {
        if (self.timeline_cursor >= self.timeline_events.len) return null;
        return &self.timeline_events[self.timeline_cursor];
    }

    fn getCurrentSelection(self: *App) ?Selection {
        if (self.view_mode == .grouped) {
            const group = self.getCurrentGroup() orelse return null;
            return Selection{
                .app_name = group.app_name,
                .window_title = group.window_title,
            };
        }

        const event = self.getCurrentTimelineEvent() orelse return null;
        return Selection{
            .app_name = event.app_name,
            .window_title = event.window_title,
        };
    }

    fn hasVisibleRows(self: *const App) bool {
        return if (self.view_mode == .grouped) self.rows.len > 0 else self.timeline_rows.len > 0;
    }

    fn toggleViewMode(self: *App) void {
        self.view_mode = if (self.view_mode == .grouped) .timeline else .grouped;
    }

    fn toggleShortEventFilter(self: *App) void {
        const enabled = self.usecase.toggleShortEventFilter();
        self.current_date_idx = 0;
        self.reloadDates() catch {
            self.status_msg = "Error reloading dates";
            self.status_is_error = true;
            return;
        };
        if (!self.should_quit) {
            self.reloadEvents() catch {
                self.status_msg = "Error reloading events";
                self.status_is_error = true;
                return;
            };
        }

        self.status_msg = if (enabled) "Filter ON: hiding events under 2s" else "Filter OFF: showing all events";
        self.status_is_error = false;
    }

    /// Perform mapping of current group's events.
    fn performGroupMapping(self: *App, match: HierarchyMatch) void {
        const group = self.getCurrentGroup() orelse {
            self.status_msg = "No group selected";
            self.status_is_error = true;
            return;
        };

        const date = self.getCurrentDate();
        self.usecase.mapEventsByGroup(date, group.app_name, group.window_title, match.activity_id, match.kind_id) catch {
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

    /// Perform mapping of a single selected timeline event.
    fn performSingleEventMapping(self: *App, match: HierarchyMatch) void {
        const event = self.getCurrentTimelineEvent() orelse {
            self.status_msg = "No event selected";
            self.status_is_error = true;
            return;
        };

        self.usecase.mapEvent(event.id, match.activity_id, match.kind_id, true) catch {
            self.status_msg = "Error mapping event";
            self.status_is_error = true;
            return;
        };

        self.mode = .normal;
        self.search_len = 0;
        self.freeSearchResults();
        self.search_cursor = 0;

        self.reloadDates() catch {};
        if (!self.should_quit) {
            self.reloadEvents() catch {};
        }

        self.status_msg = "Event mapped successfully";
        self.status_is_error = false;
    }

    /// Discard current selection in the active view.
    fn discardSelected(self: *App) void {
        if (self.view_mode == .grouped) {
            const group = self.getCurrentGroup() orelse {
                self.status_msg = "No group selected";
                self.status_is_error = true;
                return;
            };

            const date = self.getCurrentDate();
            self.usecase.discardEventsByGroup(date, group.app_name, group.window_title) catch {
                self.status_msg = "Error discarding events";
                self.status_is_error = true;
                return;
            };
        } else {
            const event = self.getCurrentTimelineEvent() orelse {
                self.status_msg = "No event selected";
                self.status_is_error = true;
                return;
            };

            self.usecase.discardEvent(event.id) catch {
                self.status_msg = "Error discarding event";
                self.status_is_error = true;
                return;
            };
        }

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

        self.search_results = self.usecase.searchFullHierarchy(self.search_buf[0..self.search_len]) catch {
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
            .rule_menu => return self.handleRuleMenuKey(key),
            .analyze => return self.handleAnalyzeKey(key),
            .accept_dialog => return self.handleAcceptDialogKey(key),
        }
    }

    fn handleRuleMenuKey(self: *App, key: vaxis.Key) bool {
        // Cancel
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
            self.mode = .normal;
            return false;
        }

        // 'a' - App only rule
        if (key.matches('a', .{})) {
            self.createFollowPreviousRule(false);
            return false;
        }

        // 't' - App + Title rule
        if (key.matches('t', .{})) {
            self.createFollowPreviousRule(true);
            return false;
        }

        return false;
    }

    fn createFollowPreviousRule(self: *App, include_title: bool) void {
        const selection = self.getCurrentSelection() orelse {
            self.status_msg = "No row selected";
            self.status_is_error = true;
            self.mode = .normal;
            return;
        };

        const title_pattern: ?[]const u8 = if (include_title) selection.window_title else null;

        self.usecase.addFollowPreviousRule(selection.app_name, title_pattern) catch {
            self.status_msg = "Error creating rule";
            self.status_is_error = true;
            self.mode = .normal;
            return;
        };

        self.mode = .normal;
        if (include_title) {
            self.status_msg = "Follow-previous rule created (app + title)";
        } else {
            self.status_msg = "Follow-previous rule created (app only)";
        }
        self.status_is_error = false;
    }

    fn applyRulesForCurrentDay(self: *App) void {
        const date = self.getCurrentDate();
        const mapped_count = self.usecase.applyRulesForDate(date) catch {
            self.status_msg = "Error applying rules";
            self.status_is_error = true;
            return;
        };

        // Reload data
        self.reloadDates() catch {};
        if (!self.should_quit) {
            self.reloadEvents() catch {};
        }

        // Format status message
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Applied rules: {d} events mapped", .{mapped_count}) catch "Rules applied";
        // Copy to static buffer since msg_buf is on stack
        @memcpy(self.status_buf[0..msg.len], msg);
        self.status_msg = self.status_buf[0..msg.len];
        self.status_is_error = false;
    }

    fn enterAnalyzeMode(self: *App) void {
        const date = self.getCurrentDate();

        // Free any previous suggestions
        self.freeSuggestions();
        self.suggestion_cursor = 0;

        // Get suggestions from analyzer
        self.suggestions = self.usecase.analyzeForDate(date) catch {
            self.status_msg = "Error analyzing events";
            self.status_is_error = true;
            return;
        };

        if (self.suggestions.len == 0) {
            self.status_msg = "No suggestions found";
            self.status_is_error = false;
            return;
        }

        self.mode = .analyze;
        self.status_msg = "";
    }

    fn handleAnalyzeKey(self: *App, key: vaxis.Key) bool {
        // Cancel
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
            self.mode = .normal;
            self.freeSuggestions();
            return false;
        }

        // Navigate suggestions
        if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) {
            if (self.suggestion_cursor > 0) {
                self.suggestion_cursor -= 1;
            }
            return false;
        }
        if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) {
            if (self.suggestion_cursor + 1 < self.suggestions.len) {
                self.suggestion_cursor += 1;
            }
            return false;
        }

        // Number keys to select (1-9)
        if (key.codepoint >= '1' and key.codepoint <= '9') {
            const idx = key.codepoint - '1';
            if (idx < self.suggestions.len) {
                self.suggestion_cursor = idx;
                self.mode = .accept_dialog;
            }
            return false;
        }

        // Enter to accept current selection
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.suggestions.len > 0 and self.suggestion_cursor < self.suggestions.len) {
                self.mode = .accept_dialog;
            }
            return false;
        }

        return false;
    }

    fn handleAcceptDialogKey(self: *App, key: vaxis.Key) bool {
        // Cancel
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
            self.mode = .analyze;
            return false;
        }

        // 'r' - Create rule only
        if (key.matches('r', .{})) {
            self.acceptCurrentSuggestion(false);
            return false;
        }

        // 'a' - Create rule AND apply now
        if (key.matches('a', .{})) {
            self.acceptCurrentSuggestion(true);
            return false;
        }

        return false;
    }

    fn acceptCurrentSuggestion(self: *App, apply_now: bool) void {
        if (self.suggestion_cursor >= self.suggestions.len) {
            self.mode = .normal;
            return;
        }

        const suggestion = self.suggestions[self.suggestion_cursor];
        const date = self.getCurrentDate();

        const mapped_count = self.usecase.acceptSuggestion(suggestion, apply_now, date) catch {
            self.status_msg = "Error accepting suggestion";
            self.status_is_error = true;
            self.mode = .normal;
            self.freeSuggestions();
            return;
        };

        // Format status message
        var msg_buf: [80]u8 = undefined;
        const msg = if (apply_now)
            std.fmt.bufPrint(&msg_buf, "Rule created, {d} events mapped", .{mapped_count}) catch "Rule created"
        else
            "Rule created (will apply to future events)";
        @memcpy(self.status_buf[0..msg.len], msg);
        self.status_msg = self.status_buf[0..msg.len];
        self.status_is_error = false;

        // Reload data if we applied
        if (apply_now) {
            self.reloadDates() catch {};
            if (!self.should_quit) {
                self.reloadEvents() catch {};
            }
        }

        self.mode = .normal;
        self.freeSuggestions();
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
                if (self.view_mode == .grouped) {
                    self.performGroupMapping(self.search_results[self.search_cursor]);
                } else {
                    self.performSingleEventMapping(self.search_results[self.search_cursor]);
                }
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

        if (key.matches('v', .{})) {
            self.toggleViewMode();
            return false;
        }

        if (key.matches('f', .{})) {
            self.toggleShortEventFilter();
            return false;
        }

        // Open search/map modal
        if (key.matches('m', .{})) {
            if (self.hasVisibleRows()) {
                self.mode = .search;
                self.search_len = 0;
                self.freeSearchResults();
            }
            return false;
        }

        // Discard current selection
        if (key.matches('d', .{})) {
            if (self.hasVisibleRows()) {
                self.discardSelected();
            }
            return false;
        }

        // Create follow-previous rule
        if (key.matches('r', .{})) {
            if (self.hasVisibleRows()) {
                self.mode = .rule_menu;
            }
            return false;
        }

        // Apply rules for current day
        if (key.matches('R', .{})) {
            self.applyRulesForCurrentDay();
            return false;
        }

        // Enter analyze mode
        if (key.matches('a', .{})) {
            self.enterAnalyzeMode();
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
            if (self.view_mode == .grouped) {
                self.table_ctx.row -|= 1;
            } else {
                self.timeline_cursor -|= 1;
            }
        }
        if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) {
            if (self.view_mode == .grouped) {
                if (self.table_ctx.row < self.rows.len -| 1) {
                    self.table_ctx.row +|= 1;
                }
            } else if (self.timeline_cursor < self.timeline_rows.len -| 1) {
                self.timeline_cursor +|= 1;
            }
        }

        // Page navigation
        if (key.matches('d', .{ .ctrl = true })) {
            if (self.view_mode == .grouped) {
                self.table_ctx.row +|= 20;
                if (self.table_ctx.row >= self.rows.len) {
                    self.table_ctx.row = @intCast(self.rows.len -| 1);
                }
            } else {
                self.timeline_cursor +|= 20;
                if (self.timeline_cursor >= self.timeline_rows.len) {
                    self.timeline_cursor = self.timeline_rows.len -| 1;
                }
            }
        }
        if (key.matches('u', .{ .ctrl = true })) {
            if (self.view_mode == .grouped) {
                self.table_ctx.row -|= 20;
            } else {
                self.timeline_cursor -|= 20;
            }
        }

        // Go to top/bottom
        if (key.matches('g', .{})) {
            if (self.view_mode == .grouped) {
                self.table_ctx.row = 0;
            } else {
                self.timeline_cursor = 0;
            }
        }
        if (key.matches('G', .{})) {
            if (self.view_mode == .grouped) {
                if (self.rows.len > 0) {
                    self.table_ctx.row = @intCast(self.rows.len - 1);
                }
            } else if (self.timeline_rows.len > 0) {
                self.timeline_cursor = self.timeline_rows.len - 1;
            }
        }

        // Clear status message
        if (key.matches(vaxis.Key.escape, .{})) {
            self.status_msg = "";
        }

        return false;
    }
};

fn convertToRows(allocator: std.mem.Allocator, groups: []GroupedEvent) ![]EventRow {
    const rows = try allocator.alloc(EventRow, groups.len);
    for (groups, 0..) |group, i| {
        rows[i] = EventRow{
            .app_name = undefined,
            .window_title = undefined,
            .count = undefined,
            .duration = undefined,
        };

        // Copy app/title while stripping control and ANSI bytes for safe TUI output.
        rows[i].app_name = sanitizeForDisplay(group.app_name, &rows[i].app_buf);
        const clean_title = sanitizeForDisplay(group.window_title, &rows[i].title_buf);
        rows[i].window_title = clean_title[0..@min(clean_title.len, 60)];

        // Format count
        const count_str = std.fmt.bufPrint(&rows[i].count_buf, "{d}", .{group.event_count}) catch "?";
        rows[i].count = count_str;

        // Format duration
        const duration_str = formatDuration(group.total_duration_ms, &rows[i].duration_buf);
        rows[i].duration = duration_str;
    }
    return rows;
}

fn convertToTimelineRows(allocator: std.mem.Allocator, events: []const UnmappedEvent) ![]TimelineRow {
    const rows = try allocator.alloc(TimelineRow, events.len);
    for (events, 0..) |event, i| {
        rows[i] = TimelineRow{
            .time_text = undefined,
            .app_name = undefined,
            .window_title = undefined,
            .duration = undefined,
            .hour = hourFromTimestampMs(event.timestamp_ms),
        };

        rows[i].time_text = formatTimeOfDay(event.timestamp_ms, &rows[i].time_buf);
        rows[i].duration = formatDuration(event.duration_ms, &rows[i].duration_buf);

        rows[i].app_name = sanitizeForDisplay(event.app_name, &rows[i].app_buf);
        rows[i].window_title = sanitizeForDisplay(event.window_title, &rows[i].title_buf);
    }
    return rows;
}

fn formatDuration(ms: i64, buf: []u8) []const u8 {
    const total_seconds_i64 = @max(@as(i64, 0), @divFloor(ms, 1000));
    const total_seconds: u64 = @intCast(total_seconds_i64);
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

/// Strip ANSI escape sequences and emit only printable ASCII for stable TUI rendering.
fn sanitizeForDisplay(input: []const u8, out: []u8) []const u8 {
    var i: usize = 0;
    var o: usize = 0;

    while (i < input.len and o < out.len) {
        const b = input[i];

        // Remove common ANSI/terminal escapes that can leak into window titles.
        if (b == 0x1b) {
            i += 1;
            if (i >= input.len) break;

            const esc_type = input[i];
            switch (esc_type) {
                // CSI: ESC [ ... <final>
                '[' => {
                    i += 1;
                    while (i < input.len) : (i += 1) {
                        const ch = input[i];
                        if (ch >= 0x40 and ch <= 0x7e) {
                            i += 1;
                            break;
                        }
                    }
                },
                // OSC: ESC ] ... BEL or ST(ESC \)
                ']' => {
                    i += 1;
                    while (i < input.len) : (i += 1) {
                        if (input[i] == 0x07) {
                            i += 1;
                            break;
                        }
                        if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '\\') {
                            i += 2;
                            break;
                        }
                    }
                },
                // DCS / PM / APC: ESC P,^,_ ... ST(ESC \)
                'P', '^', '_' => {
                    i += 1;
                    while (i < input.len) : (i += 1) {
                        if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '\\') {
                            i += 2;
                            break;
                        }
                    }
                },
                // Other 2-byte escapes: drop sequence starter and next byte.
                else => {
                        i += 1;
                },
            }
            continue;
        }

        // Drop control bytes.
        if (b < 0x20 or b == 0x7f) {
            i += 1;
            continue;
        }

        // Keep printable ASCII; replace non-ASCII bytes to avoid invalid UTF-8 artifacts.
        out[o] = if (b <= 0x7e) b else '?';
        o += 1;
        i += 1;
    }

    return out[0..o];
}

test "sanitizeForDisplay strips CSI escapes and keeps ASCII text" {
    const input = "abc\x1b[38;5;6mhello\x1b[0mxyz";
    var out: [64]u8 = undefined;
    const clean = sanitizeForDisplay(input, &out);
    try std.testing.expectEqualStrings("abchelloxyz", clean);
}

test "sanitizeForDisplay strips OSC escapes" {
    const input = "pre\x1b]0;window title\x07post";
    var out: [64]u8 = undefined;
    const clean = sanitizeForDisplay(input, &out);
    try std.testing.expectEqualStrings("prepost", clean);
}

test "sanitizeForDisplay removes controls and replaces non-ascii" {
    // "a" + bell + "b" + utf8 emoji + "c"
    const input = "a\x07b\xf0\x9f\x94\x94c";
    var out: [64]u8 = undefined;
    const clean = sanitizeForDisplay(input, &out);
    try std.testing.expectEqualStrings("ab????c", clean);
}

const Align = enum {
    left,
    right,
};

fn padAscii(buf: []u8, width: usize, text: []const u8, text_align: Align) []const u8 {
    const w = @min(width, buf.len);
    if (w == 0) return buf[0..0];

    @memset(buf[0..w], ' ');

    const src = if (text.len > w)
        switch (text_align) {
            .left => text[0..w],
            .right => text[text.len - w ..],
        }
    else
        text;

    const start = switch (text_align) {
        .left => 0,
        .right => w - src.len,
    };
    @memcpy(buf[start .. start + src.len], src);
    return buf[0..w];
}

test "padAscii left aligns and pads" {
    var buf: [16]u8 = undefined;
    const out = padAscii(&buf, 6, "ab", .left);
    try std.testing.expectEqualStrings("ab    ", out);
}

test "padAscii right aligns and pads" {
    var buf: [16]u8 = undefined;
    const out = padAscii(&buf, 6, "ab", .right);
    try std.testing.expectEqualStrings("    ab", out);
}

test "padAscii clips by alignment" {
    var buf: [16]u8 = undefined;
    const left = padAscii(&buf, 4, "abcdef", .left);
    try std.testing.expectEqualStrings("abcd", left);

    const right = padAscii(&buf, 4, "abcdef", .right);
    try std.testing.expectEqualStrings("cdef", right);
}

const ascii_glyph_table: [128][1]u8 = blk: {
    var table: [128][1]u8 = undefined;
    for (&table, 0..) |*entry, idx| {
        entry.* = .{@as(u8, @intCast(idx))};
    }
    break :blk table;
};

fn asciiGrapheme(byte: u8) []const u8 {
    const safe_byte: u8 = if (byte >= 0x20 and byte <= 0x7e) byte else '?';
    return ascii_glyph_table[safe_byte][0..1];
}

fn writeAsciiText(
    table_win: vaxis.Window,
    col: u16,
    row: u16,
    text: []const u8,
    style: vaxis.Style,
    max_width: u16,
) void {
    if (row >= table_win.height or col >= table_win.width) return;
    const width: usize = @intCast(@min(max_width, table_win.width - col));

    var i: usize = 0;
    while (i < width and i < text.len) : (i += 1) {
        table_win.writeCell(col + @as(u16, @intCast(i)), row, .{
            .char = .{
                .grapheme = asciiGrapheme(text[i]),
                .width = 1,
            },
            .style = style,
        });
    }
}

fn writeAsciiPadded(
    table_win: vaxis.Window,
    col: u16,
    row: u16,
    width: u16,
    text: []const u8,
    text_align: Align,
    style: vaxis.Style,
) void {
    if (row >= table_win.height or col >= table_win.width or width == 0) return;

    const total: usize = @intCast(width);
    const clipped = if (text.len > total)
        switch (text_align) {
            .left => text[0..total],
            .right => text[text.len - total ..],
        }
    else
        text;

    const start: usize = switch (text_align) {
        .left => 0,
        .right => total - clipped.len,
    };
    const draw_width: usize = @intCast(@min(width, table_win.width - col));

    for (0..draw_width) |i| {
        const byte: u8 = if (i >= start and i < start + clipped.len) clipped[i - start] else ' ';
        table_win.writeCell(col + @as(u16, @intCast(i)), row, .{
            .char = .{
                .grapheme = asciiGrapheme(byte),
                .width = 1,
            },
            .style = style,
        });
    }
}

fn windowRowToAscii(win: vaxis.Window, row: u16, out: []u8) void {
    for (out, 0..) |*ch, idx| {
        const col: u16 = @intCast(idx);
        const cell = win.readCell(col, row) orelse {
            ch.* = ' ';
            continue;
        };
        ch.* = if (cell.char.grapheme.len > 0) cell.char.grapheme[0] else ' ';
    }
}

test "convertToTimelineRows sanitizes and formats timeline fields" {
    const events = [_]UnmappedEvent{
        .{
            .id = 1,
            .timestamp_ms = 82_805_000, // 23:00:05
            .app_name = "Cal\x1b[31mendar",
            .window_title = "he\x07llo\xf0\x9f\x94\x94",
            .duration_ms = 2_500,
        },
    };

    const rows = try convertToTimelineRows(std.testing.allocator, &events);
    defer std.testing.allocator.free(rows);

    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(u8, 23), rows[0].hour);
    try std.testing.expectEqualStrings("23:00:05", rows[0].time_text);
    try std.testing.expectEqualStrings("Calendar", rows[0].app_name);
    try std.testing.expectEqualStrings("hello????", rows[0].window_title);
    try std.testing.expectEqualStrings("2s", rows[0].duration);
}

test "writeAsciiPadded writes aligned ASCII cells" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1,
        .cols = 6,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);

    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 6,
        .height = 1,
        .screen = &screen,
    };
    win.clear();

    writeAsciiPadded(win, 0, 0, 6, "ab", .right, .{});
    var out: [6]u8 = undefined;
    windowRowToAscii(win, 0, &out);
    try std.testing.expectEqualStrings("    ab", &out);
}

test "writeAsciiPadded clips left aligned text and replaces non-ascii" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1,
        .cols = 4,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);

    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 4,
        .height = 1,
        .screen = &screen,
    };
    win.clear();

    writeAsciiPadded(win, 0, 0, 4, "a\xffbcde", .left, .{});
    var out: [4]u8 = undefined;
    windowRowToAscii(win, 0, &out);
    try std.testing.expectEqualStrings("a?bc", &out);
}

fn fillHourStats(stats: *[24]HourStats, buckets: []HourBucket) void {
    for (buckets) |bucket| {
        if (bucket.hour < 24) {
            stats[bucket.hour] = HourStats{
                .event_count = bucket.event_count,
                .total_duration_ms = bucket.total_duration_ms,
            };
        }
    }
}

fn hourFromTimestampMs(timestamp_ms: i64) u8 {
    const total_seconds = @divFloor(timestamp_ms, 1000);
    const seconds_in_day = @mod(total_seconds, 24 * 3600);
    return @intCast(@divFloor(seconds_in_day, 3600));
}

fn formatTimeOfDay(timestamp_ms: i64, buf: []u8) []const u8 {
    const total_seconds = @divFloor(timestamp_ms, 1000);
    const seconds_in_day = @mod(total_seconds, 24 * 3600);
    const hours: u8 = @intCast(@divFloor(seconds_in_day, 3600));
    const minutes: u8 = @intCast(@divFloor(@mod(seconds_in_day, 3600), 60));
    const seconds: u8 = @intCast(@mod(seconds_in_day, 60));
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds }) catch "--:--:--";
}

fn hourHighlightColor(duration_ms: i64, max_duration_ms: i64) vaxis.Color {
    if (duration_ms <= 0 or max_duration_ms <= 0) {
        return .{ .rgb = .{ 18, 18, 22 } };
    }

    const scaled = @min(@divFloor(duration_ms * 5, max_duration_ms), 5);
    return switch (scaled) {
        0 => .{ .rgb = .{ 28, 30, 40 } },
        1 => .{ .rgb = .{ 36, 44, 60 } },
        2 => .{ .rgb = .{ 44, 56, 80 } },
        3 => .{ .rgb = .{ 52, 68, 100 } },
        4 => .{ .rgb = .{ 60, 82, 122 } },
        else => .{ .rgb = .{ 68, 96, 144 } },
    };
}

fn drawTimeline(table_win: vaxis.Window, app: *App) void {
    if (table_win.width < 20) {
        writeAsciiText(
            table_win,
            0,
            0,
            " Terminal too narrow for timeline view",
            .{ .fg = .{ .rgb = .{ 180, 120, 120 } } },
            table_win.width,
        );
        return;
    }

    const hour_col_width: u16 = @min(22, table_win.width / 3);
    const events_col_x: u16 = hour_col_width + 1;

    var max_hour_duration: i64 = 0;
    for (app.hour_stats) |hour| {
        if (hour.total_duration_ms > max_hour_duration) {
            max_hour_duration = hour.total_duration_ms;
        }
    }

    for (0..table_win.height) |y| {
        if (y < 24) {
            const hour_idx: usize = y;
            const stats = app.hour_stats[hour_idx];
            const bg = hourHighlightColor(stats.total_duration_ms, max_hour_duration);

            for (0..hour_col_width) |x| {
                table_win.writeCell(@intCast(x), @intCast(y), .{
                    .char = .{ .grapheme = " " },
                    .style = .{ .bg = bg },
                });
            }

            var duration_buf: [20]u8 = undefined;
            const dur_text = formatDuration(stats.total_duration_ms, &duration_buf);
            var hour_buf: [40]u8 = undefined;
            const hour_text = std.fmt.bufPrint(&hour_buf, " {d:0>2}:00 {s}", .{ hour_idx, dur_text }) catch " --:--";
            writeAsciiPadded(
                table_win,
                0,
                @intCast(y),
                hour_col_width,
                hour_text,
                .left,
                .{ .fg = .{ .rgb = .{ 210, 210, 220 } }, .bg = bg },
            );
        }

        table_win.writeCell(events_col_x - 1, @intCast(y), .{
            .char = .{ .grapheme = asciiGrapheme('|') },
            .style = .{ .fg = .{ .rgb = .{ 60, 60, 80 } } },
        });
    }

    if (app.timeline_rows.len == 0) {
        writeAsciiText(
            table_win,
            events_col_x,
            0,
            "  No events for this date",
            .{ .fg = .{ .rgb = .{ 128, 128, 128 } } },
            table_win.width - events_col_x,
        );
        return;
    }

    var row: u16 = 0;
    for (app.timeline_rows, 0..) |timeline_row, i| {
        if (row >= table_win.height) break;

        const selected = i == app.timeline_cursor;
        const hour = timeline_row.hour;
        const hour_bg = hourHighlightColor(app.hour_stats[hour].total_duration_ms, max_hour_duration);
        const row_bg: vaxis.Color = if (selected) .{ .rgb = .{ 50, 80, 140 } } else hour_bg;
        const fg: vaxis.Color = if (selected) .{ .rgb = .{ 255, 255, 255 } } else .{ .rgb = .{ 200, 200, 200 } };

        for (events_col_x..table_win.width) |x| {
            table_win.writeCell(@intCast(x), row, .{
                .char = .{ .grapheme = " " },
                .style = .{ .bg = row_bg },
            });
        }

        // Render fixed-width columns to prevent wrapping/drift with malformed titles.
        const events_width = table_win.width - events_col_x;
        const time_w: u16 = 8;
        const dur_w: u16 = 8;
        const sep: u16 = 1;

        const base_i32 = @as(i32, events_width) - @as(i32, time_w) - @as(i32, dur_w) - 3;
        if (base_i32 > 0) {
            var app_w_i32: i32 = @min(@as(i32, 14), @max(@as(i32, 4), @divFloor(base_i32, 4)));
            var title_w_i32: i32 = base_i32 - app_w_i32;
            if (title_w_i32 < 6) {
                const need: i32 = 6 - title_w_i32;
                if (app_w_i32 - need < 4) {
                    app_w_i32 = 4;
                } else {
                    app_w_i32 -= need;
                }
                title_w_i32 = base_i32 - app_w_i32;
            }

            const app_w: u16 = @intCast(app_w_i32);
            const title_w: u16 = @intCast(if (title_w_i32 < 0) @as(i32, 0) else title_w_i32);

            const time_col = events_col_x;
            const app_col = time_col + time_w + sep;
            const title_col = app_col + app_w + sep;
            const dur_col = title_col + title_w + sep;
            const field_style = vaxis.Style{ .fg = fg, .bg = row_bg };

            writeAsciiPadded(table_win, time_col, row, time_w, timeline_row.time_text, .left, field_style);
            writeAsciiPadded(table_win, app_col, row, app_w, timeline_row.app_name, .left, field_style);
            writeAsciiPadded(table_win, title_col, row, title_w, timeline_row.window_title, .left, field_style);
            writeAsciiPadded(table_win, dur_col, row, dur_w, timeline_row.duration, .right, field_style);
        } else {
            // Narrow fallback: keep deterministic rendering with time + clipped title.
            writeAsciiPadded(
                table_win,
                events_col_x,
                row,
                table_win.width - events_col_x,
                timeline_row.window_title,
                .left,
                .{ .fg = fg, .bg = row_bg },
            );
        }

        row += 1;
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

        var header_buf: [320]u8 = undefined;
        const current_date = app.getCurrentDate();
        const date_info_len = app.dates.len;
        const date_pos = app.current_date_idx + 1;
        const view_name = if (app.view_mode == .grouped) "Grouped" else "Timeline";
        const item_count = if (app.view_mode == .grouped) app.rows.len else app.timeline_rows.len;
        const item_label = if (app.view_mode == .grouped) "groups" else "events";
        const filter_state = if (app.usecase.isShortEventFilterEnabled()) "ON" else "OFF";
        const header_text = std.fmt.bufPrint(
            &header_buf,
            " {s} ({d}/{d}) | {s} | {d} {s} | <2s:{s} | []:Day v:View f:Filter m:Map a:Analyze r:Rule R:Apply d:Discard q:Quit",
            .{ current_date, date_pos, date_info_len, view_name, item_count, item_label, filter_state },
        ) catch "Review";
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

        if (app.view_mode == .grouped) {
            if (app.rows.len > 0) {
                try vaxis.widgets.Table.drawTable(
                    null,
                    table_win,
                    app.rows,
                    &app.table_ctx,
                );
            } else {
                _ = table_win.print(&.{.{ .text = "  No grouped events for this date", .style = .{ .fg = .{ .rgb = .{ 128, 128, 128 } } } }}, .{});
            }
        } else {
            drawTimeline(table_win, &app);
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

        // Rule menu modal
        if (app.mode == .rule_menu) {
            const modal_width: u16 = 50;
            const modal_height: u16 = 9;
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

            // Border
            for (0..modal_width) |x| {
                modal_win.writeCell(@intCast(x), 0, .{ .char = .{ .grapheme = "-" }, .style = .{ .fg = .{ .rgb = .{ 100, 100, 120 } } } });
                modal_win.writeCell(@intCast(x), modal_height -| 1, .{ .char = .{ .grapheme = "-" }, .style = .{ .fg = .{ .rgb = .{ 100, 100, 120 } } } });
            }

            // Title
            _ = modal_win.print(&.{.{ .text = " Create Follow-Previous Rule", .style = .{ .fg = .{ .rgb = .{ 200, 200, 200 } } } }}, .{ .row_offset = 1 });

            // Current selection info
            if (app.getCurrentSelection()) |selection| {
                var app_clean_buf: [60]u8 = undefined;
                const clean_app = sanitizeForDisplay(selection.app_name, &app_clean_buf);
                const app_max = @min(clean_app.len, 40);
                var app_buf: [60]u8 = undefined;
                const app_text = std.fmt.bufPrint(&app_buf, " App: {s}", .{clean_app[0..app_max]}) catch " App: ...";
                _ = modal_win.print(&.{.{ .text = app_text, .style = .{ .fg = .{ .rgb = .{ 180, 180, 180 } } } }}, .{ .row_offset = 3 });
            }

            // Options
            _ = modal_win.print(&.{.{ .text = " [a] App only (any title)", .style = .{ .fg = .{ .rgb = .{ 100, 255, 100 } } } }}, .{ .row_offset = 5 });
            _ = modal_win.print(&.{.{ .text = " [t] App + Title (exact match)", .style = .{ .fg = .{ .rgb = .{ 100, 255, 100 } } } }}, .{ .row_offset = 6 });
            _ = modal_win.print(&.{.{ .text = " [Esc] Cancel", .style = .{ .fg = .{ .rgb = .{ 100, 100, 100 } } } }}, .{ .row_offset = 7 });
        }

        // Analyze mode - full screen split view
        if (app.mode == .analyze or app.mode == .accept_dialog) {
            // Clear table area and draw split view
            const content_win = win.child(.{
                .x_off = 0,
                .y_off = 2,
                .width = win.width,
                .height = win.height -| 2,
            });
            content_win.fill(.{ .style = .{ .bg = .{ .rgb = .{ 16, 16, 16 } } } });

            // Calculate split - suggestions get right side
            const suggestions_width: u16 = @min(50, win.width / 2);
            const events_width = win.width -| suggestions_width -| 1;

            // Left side - events table
            const events_win = content_win.child(.{
                .x_off = 0,
                .y_off = 0,
                .width = events_width,
                .height = content_win.height,
            });

            // Draw vertical separator
            for (0..content_win.height) |y| {
                content_win.writeCell(events_width, @intCast(y), .{ .char = .{ .grapheme = "|" }, .style = .{ .fg = .{ .rgb = .{ 60, 60, 80 } } } });
            }

            // Right side - suggestions
            const suggestions_win = content_win.child(.{
                .x_off = events_width + 1,
                .y_off = 0,
                .width = suggestions_width,
                .height = content_win.height,
            });

            // Draw events on left (simplified table)
            _ = events_win.print(&.{.{ .text = " UNMAPPED EVENTS", .style = .{ .fg = .{ .rgb = .{ 150, 150, 180 } }, .bg = .{ .rgb = .{ 30, 30, 40 } } } }}, .{ .row_offset = 0 });
            var event_row: u16 = 1;
            for (app.groups) |group| {
                if (event_row >= events_win.height -| 1) break;
                var event_buf: [100]u8 = undefined;
                const app_len = @min(group.app_name.len, 15);
                const title_len = @min(group.window_title.len, 25);
                const event_text = std.fmt.bufPrint(&event_buf, " {s:<15} {s:<25} {d:>3}", .{ group.app_name[0..app_len], group.window_title[0..title_len], group.event_count }) catch " ...";
                _ = events_win.print(&.{.{ .text = event_text, .style = .{ .fg = .{ .rgb = .{ 180, 180, 180 } } } }}, .{ .row_offset = event_row });
                event_row += 1;
            }

            // Draw suggestions on right
            _ = suggestions_win.print(&.{.{ .text = " SUGGESTIONS", .style = .{ .fg = .{ .rgb = .{ 150, 150, 180 } }, .bg = .{ .rgb = .{ 30, 30, 40 } } } }}, .{ .row_offset = 0 });

            if (app.suggestions.len == 0) {
                _ = suggestions_win.print(&.{.{ .text = " No suggestions found", .style = .{ .fg = .{ .rgb = .{ 128, 128, 128 } } } }}, .{ .row_offset = 2 });
            } else {
                var sugg_row: u16 = 2;
                for (app.suggestions, 0..) |suggestion, i| {
                    if (sugg_row + 3 >= suggestions_win.height) break;

                    const is_selected = i == app.suggestion_cursor;
                    const fg_color: vaxis.Color = if (is_selected) .{ .rgb = .{ 255, 255, 255 } } else .{ .rgb = .{ 180, 180, 180 } };
                    const bg_color: vaxis.Color = if (is_selected) .{ .rgb = .{ 50, 70, 110 } } else .{ .rgb = .{ 16, 16, 16 } };

                    // Fill row backgrounds
                    for (0..suggestions_width) |x| {
                        suggestions_win.writeCell(@intCast(x), sugg_row, .{ .char = .{ .grapheme = " " }, .style = .{ .bg = bg_color } });
                        suggestions_win.writeCell(@intCast(x), sugg_row + 1, .{ .char = .{ .grapheme = " " }, .style = .{ .bg = bg_color } });
                        suggestions_win.writeCell(@intCast(x), sugg_row + 2, .{ .char = .{ .grapheme = " " }, .style = .{ .bg = bg_color } });
                    }

                    // Line 1: Number, confidence, and type
                    var line1_buf: [80]u8 = undefined;
                    const type_str: []const u8 = switch (suggestion.suggestion_type) {
                        .app_only => "App-only",
                        .app_and_title => "App+Title",
                    };
                    const line1 = std.fmt.bufPrint(&line1_buf, " {d}. [{d}%] {s}", .{ i + 1, suggestion.confidence, type_str }) catch " ...";
                    _ = suggestions_win.print(&.{.{ .text = line1, .style = .{ .fg = fg_color, .bg = bg_color } }}, .{ .row_offset = sugg_row });

                    // Line 2: Pattern -> Mapping
                    var line2_buf: [80]u8 = undefined;
                    const path_max = @min(suggestion.display_path.len, 35);
                    const app_max = @min(suggestion.app_pattern.len, 12);
                    const line2 = std.fmt.bufPrint(&line2_buf, "    {s} -> {s}", .{ suggestion.app_pattern[0..app_max], suggestion.display_path[0..path_max] }) catch "    ...";
                    _ = suggestions_win.print(&.{.{ .text = line2, .style = .{ .fg = .{ .rgb = .{ 140, 180, 140 } }, .bg = bg_color } }}, .{ .row_offset = sugg_row + 1 });

                    // Line 3: Impact
                    var line3_buf: [60]u8 = undefined;
                    var duration_buf: [20]u8 = undefined;
                    const duration_str = suggestion.formatDuration(&duration_buf);
                    const line3 = std.fmt.bufPrint(&line3_buf, "    Would map: {d} events ({s})", .{ suggestion.impact_count, duration_str }) catch "    Would map: ...";
                    _ = suggestions_win.print(&.{.{ .text = line3, .style = .{ .fg = .{ .rgb = .{ 120, 120, 150 } }, .bg = bg_color } }}, .{ .row_offset = sugg_row + 2 });

                    sugg_row += 4;
                }
            }

            // Footer
            const footer_row = content_win.height -| 1;
            _ = content_win.print(&.{.{ .text = " [1-9/j/k] Select  [Enter] Accept  [Esc] Back", .style = .{ .fg = .{ .rgb = .{ 100, 100, 100 } } } }}, .{ .row_offset = footer_row });
        }

        // Accept dialog overlay (on top of analyze view)
        if (app.mode == .accept_dialog) {
            const modal_width: u16 = 55;
            const modal_height: u16 = 11;
            const modal_x = (win.width -| modal_width) / 2;
            const modal_y = (win.height -| modal_height) / 2;

            const modal_win = win.child(.{
                .x_off = modal_x,
                .y_off = modal_y,
                .width = modal_width,
                .height = modal_height,
            });

            // Modal background
            modal_win.fill(.{ .style = .{ .bg = .{ .rgb = .{ 45, 45, 60 } } } });

            // Border
            for (0..modal_width) |x| {
                modal_win.writeCell(@intCast(x), 0, .{ .char = .{ .grapheme = "-" }, .style = .{ .fg = .{ .rgb = .{ 100, 100, 120 } } } });
                modal_win.writeCell(@intCast(x), modal_height -| 1, .{ .char = .{ .grapheme = "-" }, .style = .{ .fg = .{ .rgb = .{ 100, 100, 120 } } } });
            }

            // Title
            _ = modal_win.print(&.{.{ .text = " Accept Suggestion", .style = .{ .fg = .{ .rgb = .{ 220, 220, 220 } } } }}, .{ .row_offset = 1 });

            // Show selected suggestion details
            if (app.suggestion_cursor < app.suggestions.len) {
                const suggestion = app.suggestions[app.suggestion_cursor];

                var rule_buf: [60]u8 = undefined;
                const app_max = @min(suggestion.app_pattern.len, 20);
                const rule_text = std.fmt.bufPrint(&rule_buf, " Pattern: {s}", .{suggestion.app_pattern[0..app_max]}) catch " Pattern: ...";
                _ = modal_win.print(&.{.{ .text = rule_text, .style = .{ .fg = .{ .rgb = .{ 180, 180, 180 } } } }}, .{ .row_offset = 3 });

                var impact_buf: [50]u8 = undefined;
                var duration_buf: [20]u8 = undefined;
                const duration_str = suggestion.formatDuration(&duration_buf);
                const impact_text = std.fmt.bufPrint(&impact_buf, " Would map {d} events ({s})", .{ suggestion.impact_count, duration_str }) catch " Would map ...";
                _ = modal_win.print(&.{.{ .text = impact_text, .style = .{ .fg = .{ .rgb = .{ 150, 180, 150 } } } }}, .{ .row_offset = 4 });
            }

            // Options
            _ = modal_win.print(&.{.{ .text = " [r] Create rule only (future events)", .style = .{ .fg = .{ .rgb = .{ 100, 255, 100 } } } }}, .{ .row_offset = 6 });
            _ = modal_win.print(&.{.{ .text = " [a] Create rule AND apply now", .style = .{ .fg = .{ .rgb = .{ 100, 255, 100 } } } }}, .{ .row_offset = 7 });
            _ = modal_win.print(&.{.{ .text = " [Esc] Cancel", .style = .{ .fg = .{ .rgb = .{ 100, 100, 100 } } } }}, .{ .row_offset = 9 });
        }

        try vx.render(tty.writer());
    }
}
