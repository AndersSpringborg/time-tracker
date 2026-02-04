const std = @import("std");
const Event = @import("domain_event").Event;
const DuckDbRepository = @import("legacy_repository.zig").DuckDbRepository;

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
