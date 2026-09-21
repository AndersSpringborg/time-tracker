const std = @import("std");
const BufferedEvent = @import("buffered_repository.zig").BufferedEvent;
const BufferedRepository = @import("buffered_repository.zig").BufferedRepository;
const DuckDbRepository = @import("buffered_repository.zig").DuckDbRepository;
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

test "DuckDbRepository.init creates events table" {
    var repo = try DuckDbRepository.initInMemory();
    defer repo.deinit();

    // If we got here without error, the table was created
    try std.testing.expect(true);
}

test "DuckDbRepository.save inserts event into database" {
    var repo = try DuckDbRepository.initInMemory();
    defer repo.deinit();

    const event = Event{
        .timestamp_ms = 1000,
        .app_name = "Safari",
        .window_title = "Home",
    };
    repo.save(event, 2500);

    const count = try repo.countEvents();
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "DuckDbRepository.save stores correct data" {
    var repo = try DuckDbRepository.initInMemory();
    defer repo.deinit();

    const event = Event{
        .timestamp_ms = 1000,
        .app_name = "Safari",
        .window_title = "GitHub - Projects",
    };
    repo.save(event, 5000);

    const last = try repo.getLastEvent();
    try std.testing.expectEqualStrings("Safari", last.app_name);
    try std.testing.expectEqualStrings("GitHub - Projects", last.window_title);
    try std.testing.expectEqual(@as(i64, 5000), last.duration_ms);
}

test "DuckDbRepository.save handles multiple events" {
    var repo = try DuckDbRepository.initInMemory();
    defer repo.deinit();

    repo.save(Event{ .timestamp_ms = 1000, .app_name = "Safari", .window_title = "Home" }, 1000);
    repo.save(Event{ .timestamp_ms = 2000, .app_name = "Terminal", .window_title = "~" }, 3000);
    repo.save(Event{ .timestamp_ms = 5000, .app_name = "VSCode", .window_title = "main.zig" }, 2000);

    const count = try repo.countEvents();
    try std.testing.expectEqual(@as(usize, 3), count);
}
