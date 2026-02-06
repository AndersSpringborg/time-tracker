const review = @import("review");

pub const DateString = review.DateString;
pub const GroupedEvent = review.GroupedEvent;
pub const HourBucket = review.HourBucket;
pub const HierarchyMatch = review.HierarchyMatch;
pub const Reviewer = review.Reviewer;
pub const RuleSuggestion = review.RuleSuggestion;
pub const UnmappedEvent = review.UnmappedEvent;

/// Use case for review mode state and filtered data access.
/// Keeps filtering policy in application layer rather than CLI presentation.
pub const ReviewModeUseCase = struct {
    reviewer: Reviewer,
    shortEventFilterEnabled: bool = true,

    pub const shortEventThresholdMs: i64 = 2000;

    pub fn init(reviewer: Reviewer) ReviewModeUseCase {
        return .{
            .reviewer = reviewer,
            .shortEventFilterEnabled = true,
        };
    }

    pub fn isShortEventFilterEnabled(self: *const ReviewModeUseCase) bool {
        return self.shortEventFilterEnabled;
    }

    pub fn toggleShortEventFilter(self: *ReviewModeUseCase) bool {
        self.shortEventFilterEnabled = !self.shortEventFilterEnabled;
        return self.shortEventFilterEnabled;
    }

    pub fn setShortEventFilter(self: *ReviewModeUseCase, enabled: bool) void {
        self.shortEventFilterEnabled = enabled;
    }

    pub fn getMinDurationMs(self: *const ReviewModeUseCase) i64 {
        return if (self.shortEventFilterEnabled) shortEventThresholdMs else 0;
    }

    pub fn getDatesWithUnmappedEvents(self: *ReviewModeUseCase) ![]DateString {
        return self.reviewer.getDatesWithUnmappedEventsFiltered(self.getMinDurationMs());
    }

    pub fn getGroupedEventsForDate(self: *ReviewModeUseCase, date: []const u8) ![]GroupedEvent {
        return self.reviewer.getGroupedEventsForDateFiltered(date, self.getMinDurationMs());
    }

    pub fn getTimelineEventsForDate(self: *ReviewModeUseCase, date: []const u8) ![]UnmappedEvent {
        return self.reviewer.getUnmappedEventsForDateFiltered(date, self.getMinDurationMs());
    }

    pub fn getHourlySummaryForDate(self: *ReviewModeUseCase, date: []const u8) ![]HourBucket {
        return self.reviewer.getHourlyUnmappedSummaryForDate(date, self.getMinDurationMs());
    }

    pub fn mapEventsByGroup(
        self: *ReviewModeUseCase,
        date: []const u8,
        app_name: []const u8,
        window_title: []const u8,
        activity_id: i64,
        kind_id: i64,
    ) !void {
        return self.reviewer.mapEventsByGroup(date, app_name, window_title, activity_id, kind_id);
    }

    pub fn discardEventsByGroup(self: *ReviewModeUseCase, date: []const u8, app_name: []const u8, window_title: []const u8) !void {
        return self.reviewer.discardEventsByGroup(date, app_name, window_title);
    }

    pub fn mapEvent(self: *ReviewModeUseCase, event_id: i64, activity_id: i64, kind_id: i64, manually_mapped: bool) !void {
        return self.reviewer.mapEvent(event_id, activity_id, kind_id, manually_mapped);
    }

    pub fn discardEvent(self: *ReviewModeUseCase, event_id: i64) !void {
        return self.reviewer.discardEvent(event_id);
    }

    pub fn searchFullHierarchy(self: *ReviewModeUseCase, search_term: []const u8) ![]HierarchyMatch {
        return self.reviewer.searchFullHierarchy(search_term);
    }

    pub fn addFollowPreviousRule(self: *ReviewModeUseCase, app_pattern: []const u8, title_pattern: ?[]const u8) !void {
        return self.reviewer.addFollowPreviousRule(app_pattern, title_pattern);
    }

    pub fn applyRulesForDate(self: *ReviewModeUseCase, date: []const u8) !u32 {
        return self.reviewer.applyRulesForDate(date);
    }

    pub fn analyzeForDate(self: *ReviewModeUseCase, date: []const u8) ![]RuleSuggestion {
        return self.reviewer.analyzeForDate(date);
    }

    pub fn acceptSuggestion(self: *ReviewModeUseCase, suggestion: RuleSuggestion, apply_now: bool, date: []const u8) !u32 {
        return self.reviewer.acceptSuggestion(suggestion, apply_now, date);
    }
};
