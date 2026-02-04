const std = @import("std");
const Event = @import("domain_event").Event;
const FakeEventRepository = @import("fake_event_repository").FakeEventRepository;
const FakeRuleRepository = @import("fake_rule_repository").FakeRuleRepository;
const TrackEventUseCase = @import("track_event").TrackEventUseCase;

test "TrackEventUseCase saves event with computed duration" {
    var event_repo = FakeEventRepository.init(std.testing.allocator);
    defer event_repo.deinit();

    var rule_repo = FakeRuleRepository.init(std.testing.allocator);
    defer rule_repo.deinit();

    var usecase = TrackEventUseCase.init(event_repo.repository(), rule_repo.repository());

    // First event at t=1000
    const event1 = Event{
        .timestamp_ms = 1000,
        .app_name = "Safari",
        .window_title = "Google",
        .wifi_ssid = "Home",
    };
    usecase.handle(event1);

    // No event saved yet (need second event to compute duration)
    try std.testing.expectEqual(@as(i64, 0), event_repo.countEvents());

    // Second event at t=1500 (500ms later)
    const event2 = Event{
        .timestamp_ms = 1500,
        .app_name = "Code",
        .window_title = "main.zig",
        .wifi_ssid = "Home",
    };
    usecase.handle(event2);

    // Now first event should be saved with duration 500ms
    try std.testing.expectEqual(@as(i64, 1), event_repo.countEvents());

    const last = event_repo.getLastEvent();
    try std.testing.expect(last != null);
    try std.testing.expectEqualStrings("Safari", last.?.app_name);
    try std.testing.expectEqual(@as(i64, 500), last.?.duration_ms);
}

test "TrackEventUseCase ignores duplicate events" {
    var event_repo = FakeEventRepository.init(std.testing.allocator);
    defer event_repo.deinit();

    var rule_repo = FakeRuleRepository.init(std.testing.allocator);
    defer rule_repo.deinit();

    var usecase = TrackEventUseCase.init(event_repo.repository(), rule_repo.repository());

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
    try std.testing.expectEqual(@as(i64, 0), event_repo.countEvents());
}

test "TrackEventUseCase tracks multiple events" {
    var event_repo = FakeEventRepository.init(std.testing.allocator);
    defer event_repo.deinit();

    var rule_repo = FakeRuleRepository.init(std.testing.allocator);
    defer rule_repo.deinit();

    var usecase = TrackEventUseCase.init(event_repo.repository(), rule_repo.repository());

    // Event sequence: Safari -> Code -> Terminal
    usecase.handle(Event{ .timestamp_ms = 1000, .app_name = "Safari", .window_title = "Google", .wifi_ssid = "Home" });
    usecase.handle(Event{ .timestamp_ms = 2000, .app_name = "Code", .window_title = "main.zig", .wifi_ssid = "Home" });
    usecase.handle(Event{ .timestamp_ms = 3500, .app_name = "Terminal", .window_title = "zsh", .wifi_ssid = "Home" });

    // Two events saved (Safari: 1000ms, Code: 1500ms)
    try std.testing.expectEqual(@as(i64, 2), event_repo.countEvents());
}

test "TrackEventUseCase applies matching rule to event" {
    var event_repo = FakeEventRepository.init(std.testing.allocator);
    defer event_repo.deinit();

    var rule_repo = FakeRuleRepository.init(std.testing.allocator);
    defer rule_repo.deinit();

    // Add a rule that matches Safari
    try rule_repo.addRule(.{
        .app_pattern = "Safari",
        .title_pattern = null,
        .activity_id = 100,
        .kind_id = 200,
    });

    var usecase = TrackEventUseCase.init(event_repo.repository(), rule_repo.repository());

    // Safari event should get mapped
    usecase.handle(Event{ .timestamp_ms = 1000, .app_name = "Safari", .window_title = "Google", .wifi_ssid = "Home" });
    usecase.handle(Event{ .timestamp_ms = 2000, .app_name = "Code", .window_title = "main.zig", .wifi_ssid = "Home" });

    const last = event_repo.getLastEvent();
    try std.testing.expect(last != null);
    try std.testing.expectEqual(@as(?i64, 100), last.?.activity_id);
    try std.testing.expectEqual(@as(?i64, 200), last.?.kind_id);
}

test "TrackEventUseCase leaves unmapped events without activity/kind" {
    var event_repo = FakeEventRepository.init(std.testing.allocator);
    defer event_repo.deinit();

    var rule_repo = FakeRuleRepository.init(std.testing.allocator);
    defer rule_repo.deinit();

    // Add a rule that matches Safari (but we'll use Code)
    try rule_repo.addRule(.{
        .app_pattern = "Safari",
        .title_pattern = null,
        .activity_id = 100,
        .kind_id = 200,
    });

    var usecase = TrackEventUseCase.init(event_repo.repository(), rule_repo.repository());

    // Code event should NOT get mapped (no matching rule)
    usecase.handle(Event{ .timestamp_ms = 1000, .app_name = "Code", .window_title = "main.zig", .wifi_ssid = "Home" });
    usecase.handle(Event{ .timestamp_ms = 2000, .app_name = "Terminal", .window_title = "zsh", .wifi_ssid = "Home" });

    const last = event_repo.getLastEvent();
    try std.testing.expect(last != null);
    try std.testing.expectEqual(@as(?i64, null), last.?.activity_id);
    try std.testing.expectEqual(@as(?i64, null), last.?.kind_id);
}
