const std = @import("std");
const Event = @import("domain_event").Event;
const FakeEventRepository = @import("fake_event_repository").FakeEventRepository;
const TrackEventUseCase = @import("track_event").TrackEventUseCase;

test "TrackEventUseCase saves event with computed duration" {
    var repo = FakeEventRepository.init(std.testing.allocator);
    defer repo.deinit();

    var usecase = TrackEventUseCase.init(repo.repository());

    // First event at t=1000
    const event1 = Event{
        .timestamp_ms = 1000,
        .app_name = "Safari",
        .window_title = "Google",
        .wifi_ssid = "Home",
    };
    usecase.handle(event1);

    // No event saved yet (need second event to compute duration)
    try std.testing.expectEqual(@as(i64, 0), repo.countEvents());

    // Second event at t=1500 (500ms later)
    const event2 = Event{
        .timestamp_ms = 1500,
        .app_name = "Code",
        .window_title = "main.zig",
        .wifi_ssid = "Home",
    };
    usecase.handle(event2);

    // Now first event should be saved with duration 500ms
    try std.testing.expectEqual(@as(i64, 1), repo.countEvents());

    const last = repo.getLastEvent();
    try std.testing.expect(last != null);
    try std.testing.expectEqualStrings("Safari", last.?.app_name);
    try std.testing.expectEqual(@as(i64, 500), last.?.duration_ms);
}

test "TrackEventUseCase ignores duplicate events" {
    var repo = FakeEventRepository.init(std.testing.allocator);
    defer repo.deinit();

    var usecase = TrackEventUseCase.init(repo.repository());

    const event = Event{
        .timestamp_ms = 1000,
        .app_name = "Safari",
        .window_title = "Google",
        .wifi_ssid = "Home",
    };

    // Send same event twice
    usecase.handle(event);
    usecase.handle(event);

    // Still no saved events (waiting for different event)
    try std.testing.expectEqual(@as(i64, 0), repo.countEvents());
}

test "TrackEventUseCase tracks multiple events" {
    var repo = FakeEventRepository.init(std.testing.allocator);
    defer repo.deinit();

    var usecase = TrackEventUseCase.init(repo.repository());

    // Event sequence: Safari -> Code -> Terminal
    usecase.handle(Event{ .timestamp_ms = 1000, .app_name = "Safari", .window_title = "Google", .wifi_ssid = "Home" });
    usecase.handle(Event{ .timestamp_ms = 2000, .app_name = "Code", .window_title = "main.zig", .wifi_ssid = "Home" });
    usecase.handle(Event{ .timestamp_ms = 3500, .app_name = "Terminal", .window_title = "zsh", .wifi_ssid = "Home" });

    // Two events saved (Safari: 1000ms, Code: 1500ms)
    try std.testing.expectEqual(@as(i64, 2), repo.countEvents());
}
