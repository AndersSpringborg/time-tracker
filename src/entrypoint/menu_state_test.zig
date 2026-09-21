const std = @import("std");
const testing = std.testing;
const menu_state = @import("menu_state");
const status_client = @import("status_client");

fn snapshotOf(count: i64, matched: bool, project: []const u8, activity: []const u8) status_client.Snapshot {
    var snapshot = status_client.Snapshot{ .unmatched_count = count, .matched = matched };
    @memcpy(snapshot.project_buf[0..project.len], project);
    snapshot.project_len = project.len;
    @memcpy(snapshot.activity_buf[0..activity.len], activity);
    snapshot.activity_len = activity.len;
    return snapshot;
}

test "the focused window is remembered for the next refresh" {
    var state = menu_state.MenuState{};

    state.setWindow("Ghostty", "zig build test");

    var window_buf: menu_state.WindowText = undefined;
    const window = state.window(&window_buf);
    try testing.expectEqualStrings("Ghostty", window.app_name);
    try testing.expectEqualStrings("zig build test", window.window_title);
}

test "window text longer than the menu can show is truncated, not dropped" {
    var state = menu_state.MenuState{};
    const long = [_]u8{'x'} ** (status_client.max_window_text * 2);

    state.setWindow("Ghostty", &long);

    var window_buf: menu_state.WindowText = undefined;
    const window = state.window(&window_buf);
    try testing.expectEqual(status_client.max_window_text, window.window_title.len);
}

test "a fresh snapshot replaces the cached one and is not stale" {
    var state = menu_state.MenuState{};

    state.recordSnapshot(snapshotOf(42, true, "Time Tracker", "Development"));

    const cached = state.snapshot();
    try testing.expectEqual(@as(i64, 42), cached.unmatched_count);
    try testing.expect(cached.matched);
    try testing.expectEqualStrings("Time Tracker", cached.project());
    try testing.expect(!state.isStale());
}

test "a failed refresh keeps the last snapshot and marks it stale" {
    var state = menu_state.MenuState{};
    state.recordSnapshot(snapshotOf(42, true, "Time Tracker", "Development"));

    state.recordFailure();

    const cached = state.snapshot();
    try testing.expectEqual(@as(i64, 42), cached.unmatched_count);
    try testing.expectEqualStrings("Time Tracker", cached.project());
    try testing.expect(state.isStale());
}

test "a later successful refresh clears the stale mark" {
    var state = menu_state.MenuState{};
    state.recordFailure();
    try testing.expect(state.isStale());

    state.recordSnapshot(snapshotOf(1, false, "", ""));

    try testing.expect(!state.isStale());
}

test "an untouched state has nothing cached and is stale" {
    var state = menu_state.MenuState{};

    try testing.expect(state.isStale());
    try testing.expectEqual(@as(i64, 0), state.snapshot().unmatched_count);
}

test "reads and writes from several threads stay consistent" {
    var state = menu_state.MenuState{};

    const Writer = struct {
        fn go(s: *menu_state.MenuState) void {
            var i: usize = 0;
            while (i < 200) : (i += 1) {
                s.setWindow("Ghostty", "zig build test");
                s.recordSnapshot(snapshotOf(7, true, "Time Tracker", "Development"));
            }
        }
    };
    const Reader = struct {
        fn go(s: *menu_state.MenuState) void {
            var i: usize = 0;
            while (i < 200) : (i += 1) {
                var window_buf: menu_state.WindowText = undefined;
                _ = s.window(&window_buf);
                _ = s.snapshot();
            }
        }
    };

    const writer = try std.Thread.spawn(.{}, Writer.go, .{&state});
    const reader = try std.Thread.spawn(.{}, Reader.go, .{&state});
    writer.join();
    reader.join();

    try testing.expectEqualStrings("Time Tracker", state.snapshot().project());
}
