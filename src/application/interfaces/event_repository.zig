const std = @import("std");
const Event = @import("../../domain/event.zig").Event;

/// Stored event with database ID and computed duration.
pub const StoredEvent = struct {
    id: i64,
    timestamp_ms: i64,
    app_name: []const u8,
    window_title: []const u8,
    wifi_ssid: []const u8,
    duration_ms: i64,
    activity_id: ?i64,
    kind_id: ?i64,
    manually_mapped: bool,
};

/// Interface for persisting and retrieving events.
/// Implementations: DuckDbEventRepository, BufferedEventRepository
pub const EventRepository = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        save: *const fn (*anyopaque, Event, i64) void,
        getLastEvent: *const fn (*anyopaque) ?StoredEvent,
        countEvents: *const fn (*anyopaque) i64,
    };

    /// Save an event with its duration.
    pub fn save(self: EventRepository, event: Event, duration_ms: i64) void {
        self.vtable.save(self.ptr, event, duration_ms);
    }

    /// Get the most recent event.
    pub fn getLastEvent(self: EventRepository) ?StoredEvent {
        return self.vtable.getLastEvent(self.ptr);
    }

    /// Count total events in the repository.
    pub fn countEvents(self: EventRepository) i64 {
        return self.vtable.countEvents(self.ptr);
    }

    /// Create an EventRepository from any type that implements the required methods.
    pub fn init(impl: anytype) EventRepository {
        const Impl = @TypeOf(impl);
        const impl_ptr = if (@typeInfo(Impl) == .pointer) impl else @as(*@TypeOf(impl.*), @ptrCast(@constCast(&impl)));

        const gen = struct {
            fn save(ptr: *anyopaque, event: Event, duration_ms: i64) void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                self.save(event, duration_ms);
            }

            fn getLastEvent(ptr: *anyopaque) ?StoredEvent {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.getLastEvent();
            }

            fn countEvents(ptr: *anyopaque) i64 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.countEvents();
            }
        };

        return .{
            .ptr = impl_ptr,
            .vtable = &.{
                .save = gen.save,
                .getLastEvent = gen.getLastEvent,
                .countEvents = gen.countEvents,
            },
        };
    }
};
