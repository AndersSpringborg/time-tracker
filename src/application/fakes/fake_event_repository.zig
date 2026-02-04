const std = @import("std");
const Event = @import("domain_event").Event;
const StoredEvent = @import("event_repository").StoredEvent;
const EventRepository = @import("event_repository").EventRepository;

/// In-memory fake implementation of EventRepository for testing.
pub const FakeEventRepository = struct {
    events: std.ArrayListUnmanaged(SavedEvent),
    allocator: std.mem.Allocator,
    next_id: i64,

    const SavedEvent = struct {
        id: i64,
        event: Event,
        duration_ms: i64,
    };

    pub fn init(allocator: std.mem.Allocator) FakeEventRepository {
        return .{
            .events = .{},
            .allocator = allocator,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *FakeEventRepository) void {
        self.events.deinit(self.allocator);
    }

    pub fn save(self: *FakeEventRepository, event: Event, duration_ms: i64) void {
        self.events.append(self.allocator, .{
            .id = self.next_id,
            .event = event,
            .duration_ms = duration_ms,
        }) catch return;
        self.next_id += 1;
    }

    pub fn getLastEvent(self: *FakeEventRepository) ?StoredEvent {
        if (self.events.items.len == 0) return null;
        const last = self.events.items[self.events.items.len - 1];
        return StoredEvent{
            .id = last.id,
            .timestamp_ms = last.event.timestamp_ms,
            .app_name = last.event.app_name,
            .window_title = last.event.window_title,
            .wifi_ssid = last.event.wifi_ssid,
            .duration_ms = last.duration_ms,
            .activity_id = null,
            .kind_id = null,
            .manually_mapped = false,
        };
    }

    pub fn countEvents(self: *FakeEventRepository) i64 {
        return @intCast(self.events.items.len);
    }

    /// Convert to the interface type.
    pub fn repository(self: *FakeEventRepository) EventRepository {
        return EventRepository{
            .ptr = self,
            .vtable = &.{
                .save = saveVtable,
                .getLastEvent = getLastEventVtable,
                .countEvents = countEventsVtable,
            },
        };
    }

    fn saveVtable(ptr: *anyopaque, event: Event, duration_ms: i64) void {
        const self: *FakeEventRepository = @ptrCast(@alignCast(ptr));
        self.save(event, duration_ms);
    }

    fn getLastEventVtable(ptr: *anyopaque) ?StoredEvent {
        const self: *FakeEventRepository = @ptrCast(@alignCast(ptr));
        return self.getLastEvent();
    }

    fn countEventsVtable(ptr: *anyopaque) i64 {
        const self: *FakeEventRepository = @ptrCast(@alignCast(ptr));
        return self.countEvents();
    }
};

test "FakeEventRepository saves and retrieves events" {
    var repo = FakeEventRepository.init(std.testing.allocator);
    defer repo.deinit();

    const event = Event{
        .timestamp_ms = 1000,
        .app_name = "Safari",
        .window_title = "Google",
        .wifi_ssid = "Home",
    };

    repo.save(event, 500);

    try std.testing.expectEqual(@as(i64, 1), repo.countEvents());

    const last = repo.getLastEvent();
    try std.testing.expect(last != null);
    try std.testing.expectEqualStrings("Safari", last.?.app_name);
    try std.testing.expectEqual(@as(i64, 500), last.?.duration_ms);
}

test "FakeEventRepository works through interface" {
    var fake = FakeEventRepository.init(std.testing.allocator);
    defer fake.deinit();

    const repo = fake.repository();

    const event = Event{
        .timestamp_ms = 2000,
        .app_name = "Code",
        .window_title = "main.zig",
        .wifi_ssid = "Office",
    };

    repo.save(event, 1000);

    try std.testing.expectEqual(@as(i64, 1), repo.countEvents());
}
