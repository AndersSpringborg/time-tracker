const std = @import("std");
const Tracker = @import("tracker.zig").Tracker;
const Event = @import("domain_event").Event;

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

test "Tracker does not save until the dominant window changes" {
    var repo = MockRepository{};
    var tracker = Tracker.init(&repo);

    tracker.onEvent("Safari", "Home", 0);
    tracker.flushBucket(5000); // dominant Safari becomes pending, nothing emitted yet

    try std.testing.expectEqual(@as(u32, 0), repo.save_count);
}

test "Tracker coalesces the same dominant window across buckets and emits on change" {
    var repo = MockRepository{};
    var tracker = Tracker.init(&repo);

    tracker.onEvent("Safari", "Home", 0);
    tracker.flushBucket(5000); // pending = Safari, start = 0
    tracker.flushBucket(10000); // still Safari -> coalesced, no emit
    tracker.onEvent("Terminal", "~", 10000);
    tracker.flushBucket(15000); // dominant now Terminal -> emit Safari

    try std.testing.expectEqual(@as(u32, 1), repo.save_count);
    try std.testing.expectEqualStrings("Safari", repo.getLastAppName());
    try std.testing.expectEqualStrings("Home", repo.getLastTitle());
    try std.testing.expectEqual(@as(i64, 0), repo.last_saved_timestamp);
    try std.testing.expectEqual(@as(i64, 10000), repo.last_saved_duration.?);
}

test "Tracker picks the window with the most accumulated time in a bucket" {
    var repo = MockRepository{};
    var tracker = Tracker.init(&repo);

    tracker.onEvent("Safari", "Home", 0);
    tracker.onEvent("Terminal", "~", 1000); // Safari got 1000ms
    tracker.onEvent("Safari", "Home", 4500); // Terminal got 3500ms
    tracker.flushBucket(5000); // Safari +500 = 1500ms, Terminal 3500ms -> Terminal wins
    tracker.finish(5000); // flush trailing pending at the bucket boundary

    try std.testing.expectEqual(@as(u32, 1), repo.save_count);
    try std.testing.expectEqualStrings("Terminal", repo.getLastAppName());
}

test "Tracker.finish emits the trailing pending window" {
    var repo = MockRepository{};
    var tracker = Tracker.init(&repo);

    tracker.onEvent("VSCode", "main.zig", 0);
    tracker.flushBucket(5000); // pending = VSCode, start = 0
    tracker.finish(8000);

    try std.testing.expectEqual(@as(u32, 1), repo.save_count);
    try std.testing.expectEqualStrings("VSCode", repo.getLastAppName());
    try std.testing.expectEqual(@as(i64, 8000), repo.last_saved_duration.?);
}

test "Tracker filters a quick blip that never dominates a bucket" {
    var repo = MockRepository{};
    var tracker = Tracker.init(&repo);

    tracker.onEvent("Safari", "Home", 0);
    tracker.onEvent("Terminal", "~", 500); // brief blip
    tracker.onEvent("Safari", "Home", 1000); // back to Safari
    tracker.flushBucket(5000); // Safari 4500ms vs Terminal 500ms -> Safari dominant
    tracker.finish(10000);

    try std.testing.expectEqual(@as(u32, 1), repo.save_count);
    try std.testing.expectEqualStrings("Safari", repo.getLastAppName());
}
