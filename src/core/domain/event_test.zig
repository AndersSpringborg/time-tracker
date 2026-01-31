const std = @import("std");
const Event = @import("event").Event;

test "Event.durationUntil calculates time between events" {
    const prev = Event{
        .timestamp_ms = 1000,
        .app_name = "Safari",
        .window_title = "Home",
    };
    const curr = Event{
        .timestamp_ms = 3500,
        .app_name = "Terminal",
        .window_title = "~",
    };
    try std.testing.expectEqual(@as(i64, 2500), prev.durationUntil(curr));
}

test "Event.durationUntil returns 0 for same timestamp" {
    const e1 = Event{
        .timestamp_ms = 1000,
        .app_name = "A",
        .window_title = "B",
    };
    const e2 = Event{
        .timestamp_ms = 1000,
        .app_name = "C",
        .window_title = "D",
    };
    try std.testing.expectEqual(@as(i64, 0), e1.durationUntil(e2));
}

test "Event.eql returns true for same app and title" {
    const e1 = Event{
        .timestamp_ms = 1000,
        .app_name = "Safari",
        .window_title = "Home",
    };
    const e2 = Event{
        .timestamp_ms = 2000,
        .app_name = "Safari",
        .window_title = "Home",
    };
    try std.testing.expect(e1.eql(e2));
}

test "Event.eql returns false for different app" {
    const e1 = Event{
        .timestamp_ms = 1000,
        .app_name = "Safari",
        .window_title = "Home",
    };
    const e2 = Event{
        .timestamp_ms = 2000,
        .app_name = "Terminal",
        .window_title = "Home",
    };
    try std.testing.expect(!e1.eql(e2));
}

test "Event.eql returns false for different title" {
    const e1 = Event{
        .timestamp_ms = 1000,
        .app_name = "Safari",
        .window_title = "Home",
    };
    const e2 = Event{
        .timestamp_ms = 2000,
        .app_name = "Safari",
        .window_title = "Settings",
    };
    try std.testing.expect(!e1.eql(e2));
}
