const std = @import("std");
const BufferedEvent = @import("buffered_repository.zig").BufferedEvent;
const BufferedRepository = @import("buffered_repository.zig").BufferedRepository;
const Event = @import("domain_event").Event;

test "BufferedEvent.fromEvent copies data correctly" {
    const event = Event{
        .timestamp_ms = 1234567890,
        .app_name = "TestApp",
        .window_title = "Test Window",
        .wifi_ssid = "HomeWifi",
    };

    const buffered = BufferedEvent.fromEvent(event, 5000);

    try std.testing.expectEqual(@as(i64, 1234567890), buffered.timestamp_ms);
    try std.testing.expectEqual(@as(i64, 5000), buffered.duration_ms);
    try std.testing.expectEqualStrings("TestApp", buffered.app_name_buf[0..buffered.app_name_len]);
    try std.testing.expectEqualStrings("Test Window", buffered.window_title_buf[0..buffered.window_title_len]);
    try std.testing.expectEqualStrings("HomeWifi", buffered.wifi_ssid_buf[0..buffered.wifi_ssid_len]);
}

test "BufferedEvent.toEvent reconstructs event" {
    const event = Event{
        .timestamp_ms = 9876543210,
        .app_name = "MyApp",
        .window_title = "My Window Title",
        .wifi_ssid = "OfficeNet",
    };

    const buffered = BufferedEvent.fromEvent(event, 3000);
    const reconstructed = buffered.toEvent();

    try std.testing.expectEqual(@as(i64, 9876543210), reconstructed.timestamp_ms);
    try std.testing.expectEqualStrings("MyApp", reconstructed.app_name);
    try std.testing.expectEqualStrings("My Window Title", reconstructed.window_title);
    try std.testing.expectEqualStrings("OfficeNet", reconstructed.wifi_ssid);
}

test "BufferedEvent handles empty strings" {
    const event = Event{
        .timestamp_ms = 1000,
        .app_name = "",
        .window_title = "",
        .wifi_ssid = "",
    };

    const buffered = BufferedEvent.fromEvent(event, 100);
    const reconstructed = buffered.toEvent();

    try std.testing.expectEqual(@as(usize, 0), reconstructed.app_name.len);
    try std.testing.expectEqual(@as(usize, 0), reconstructed.window_title.len);
    try std.testing.expectEqual(@as(usize, 0), reconstructed.wifi_ssid.len);
}

test "BufferedEvent truncates long strings" {
    // Create a string longer than 256 bytes
    var long_app: [300]u8 = undefined;
    @memset(&long_app, 'A');

    const event = Event{
        .timestamp_ms = 1000,
        .app_name = &long_app,
        .window_title = "Normal",
        .wifi_ssid = "",
    };

    const buffered = BufferedEvent.fromEvent(event, 100);

    // Should be truncated to 256
    try std.testing.expectEqual(@as(usize, 256), buffered.app_name_len);
}

fn testEvent(timestamp_ms: i64) Event {
    return Event{
        .timestamp_ms = timestamp_ms,
        .app_name = "TestApp",
        .window_title = "Window",
        .wifi_ssid = "Wifi",
    };
}

test "BufferedRepository keeps small baseline capacity after successful flush" {
    var repo = BufferedRepository.init(std.testing.allocator, ":memory:");
    defer repo.deinit();

    const total = BufferedRepository.MIN_BUFFER_CAPACITY + 80;
    for (0..total) |i| {
        const ts: i64 = @intCast(i + 1);
        repo.save(testEvent(ts), 1000);
    }

    try std.testing.expectEqual(total, repo.bufferedCount());
    const grown_capacity = repo.bufferedCapacity();
    try std.testing.expect(grown_capacity > BufferedRepository.MIN_BUFFER_CAPACITY);

    repo.flushToDb();

    try std.testing.expectEqual(@as(usize, 0), repo.bufferedCount());
    try std.testing.expectEqual(BufferedRepository.MIN_BUFFER_CAPACITY, repo.bufferedCapacity());
}

test "BufferedRepository preserves buffered events on flush failure" {
    var repo = BufferedRepository.init(std.testing.allocator, "/definitely-missing-dir/time-tracker/memory-test.db");
    defer repo.deinit();

    repo.save(testEvent(1), 1000);
    const before_capacity = repo.bufferedCapacity();

    repo.flushToDb();

    try std.testing.expectEqual(@as(usize, 1), repo.bufferedCount());
    try std.testing.expectEqual(before_capacity, repo.bufferedCapacity());
}
