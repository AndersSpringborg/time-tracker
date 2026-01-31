const Event = @import("event").Event;

/// Repository interface for persisting events.
/// Any type with a `save(event: Event, duration_ms: i64) void` method
/// can be used as a repository with the Tracker.
///
/// Example implementation:
/// ```zig
/// const MyRepository = struct {
///     pub fn save(self: *MyRepository, event: Event, duration_ms: i64) void {
///         // persist the event
///     }
/// };
/// ```
pub const EventRepository = struct {
    ptr: *anyopaque,
    saveFn: *const fn (*anyopaque, Event, i64) void,

    pub fn init(repo: anytype) EventRepository {
        const Ptr = @TypeOf(repo);
        const impl = struct {
            fn save(ctx: *anyopaque, event: Event, duration_ms: i64) void {
                const ptr: Ptr = @ptrCast(@alignCast(ctx));
                ptr.save(event, duration_ms);
            }
        };
        return EventRepository{
            .ptr = @ptrCast(repo),
            .saveFn = impl.save,
        };
    }

    pub fn save(self: EventRepository, event: Event, duration_ms: i64) void {
        self.saveFn(self.ptr, event, duration_ms);
    }
};
