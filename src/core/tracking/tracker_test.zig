const std = @import("std");
const Tracker = @import("tracker").Tracker;
const Event = @import("event").Event;

/// Mock repository that records the last saved event (copies strings)
const MockRepository = struct {
    last_saved_app: [256]u8 = undefined,
    last_saved_app_len: usize = 0,
    last_saved_title: [512]u8 = undefined,
    last_saved_title_len: usize = 0,
    last_saved_timestamp: i64 = 0,
    last_saved_duration: ?i64 = null,
    save_count: u32 = 0,

    pub fn save(self: *MockRepository, event: Event, duration_ms: i64) void {
        // Copy the strings to owned buffers
        self.last_saved_app_len = event.app_name.len;
        @memcpy(self.last_saved_app[0..event.app_name.len], event.app_name);

        self.last_saved_title_len = event.window_title.len;
        @memcpy(self.last_saved_title[0..event.window_title.len], event.window_title);

        self.last_saved_timestamp = event.timestamp_ms;
        self.last_saved_duration = duration_ms;
        self.save_count += 1;
    }

    pub fn getLastAppName(self: *const MockRepository) []const u8 {
        return self.last_saved_app[0..self.last_saved_app_len];
    }

    pub fn getLastTitle(self: *const MockRepository) []const u8 {
        return self.last_saved_title[0..self.last_saved_title_len];
    }
};

test "Tracker.onEvent does not save on first event (no previous to record)" {
    var repo = MockRepository{};
    var tracker = Tracker.init(&repo);

    tracker.onEvent("Safari", "Home", 1000);

    try std.testing.expectEqual(@as(u32, 0), repo.save_count);
}

test "Tracker.onEvent saves previous event with duration on second event" {
    var repo = MockRepository{};
    var tracker = Tracker.init(&repo);

    tracker.onEvent("Safari", "Home", 1000);
    tracker.onEvent("Terminal", "~", 3500);

    try std.testing.expectEqual(@as(u32, 1), repo.save_count);
    try std.testing.expectEqual(@as(i64, 2500), repo.last_saved_duration.?);
    try std.testing.expectEqualStrings("Safari", repo.getLastAppName());
    try std.testing.expectEqualStrings("Home", repo.getLastTitle());
}

test "Tracker.onEvent ignores duplicate events (same app and title)" {
    var repo = MockRepository{};
    var tracker = Tracker.init(&repo);

    tracker.onEvent("Safari", "Home", 1000);
    tracker.onEvent("Safari", "Home", 2000); // duplicate, should be ignored
    tracker.onEvent("Safari", "Home", 3000); // duplicate, should be ignored
    tracker.onEvent("Terminal", "~", 4000); // new event, should trigger save

    try std.testing.expectEqual(@as(u32, 1), repo.save_count);
    // Duration should be from first Safari event (1000) to Terminal (4000) = 3000ms
    try std.testing.expectEqual(@as(i64, 3000), repo.last_saved_duration.?);
}

test "Tracker.onEvent tracks multiple transitions correctly" {
    var repo = MockRepository{};
    var tracker = Tracker.init(&repo);

    tracker.onEvent("Safari", "Home", 1000);
    tracker.onEvent("Terminal", "~", 2000); // saves Safari, duration 1000
    tracker.onEvent("VSCode", "main.zig", 5000); // saves Terminal, duration 3000

    try std.testing.expectEqual(@as(u32, 2), repo.save_count);
    try std.testing.expectEqualStrings("Terminal", repo.getLastAppName());
    try std.testing.expectEqual(@as(i64, 3000), repo.last_saved_duration.?);
}

test "Tracker.onEvent handles title change within same app" {
    var repo = MockRepository{};
    var tracker = Tracker.init(&repo);

    tracker.onEvent("Safari", "Home", 1000);
    tracker.onEvent("Safari", "Settings", 2000); // different title, should save

    try std.testing.expectEqual(@as(u32, 1), repo.save_count);
    try std.testing.expectEqualStrings("Safari", repo.getLastAppName());
    try std.testing.expectEqualStrings("Home", repo.getLastTitle());
    try std.testing.expectEqual(@as(i64, 1000), repo.last_saved_duration.?);
}
