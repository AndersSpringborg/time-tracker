const Event = @import("../../domain/event.zig").Event;

/// Error type for window tracker operations.
pub const WindowTrackerError = error{
    PermissionDenied,
    StartFailed,
};

/// Callback type for receiving window change events.
pub const EventCallback = *const fn (Event) void;

/// Interface for tracking active window changes.
/// Implementations: MacOsWindowTracker (Swift), MockWindowTracker (testing)
pub const WindowTracker = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        checkAccessibility: *const fn (*anyopaque) bool,
        startListening: *const fn (*anyopaque, EventCallback) WindowTrackerError!void,
        stopListening: *const fn (*anyopaque) void,
    };

    /// Check if the app has accessibility permissions.
    pub fn checkAccessibility(self: WindowTracker) bool {
        return self.vtable.checkAccessibility(self.ptr);
    }

    /// Start listening for window change events.
    /// The callback will be invoked on the main thread when the active window changes.
    /// This typically blocks the calling thread (runs the event loop).
    pub fn startListening(self: WindowTracker, callback: EventCallback) WindowTrackerError!void {
        return self.vtable.startListening(self.ptr, callback);
    }

    /// Stop listening for window changes.
    pub fn stopListening(self: WindowTracker) void {
        self.vtable.stopListening(self.ptr);
    }

    /// Create a WindowTracker from any type that implements the required methods.
    pub fn init(impl: anytype) WindowTracker {
        const Impl = @TypeOf(impl);
        const impl_ptr = if (@typeInfo(Impl) == .pointer) impl else @as(*@TypeOf(impl.*), @ptrCast(@constCast(&impl)));

        const gen = struct {
            fn checkAccessibility(ptr: *anyopaque) bool {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.checkAccessibility();
            }

            fn startListening(ptr: *anyopaque, callback: EventCallback) WindowTrackerError!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.startListening(callback);
            }

            fn stopListening(ptr: *anyopaque) void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                self.stopListening();
            }
        };

        return .{
            .ptr = impl_ptr,
            .vtable = &.{
                .checkAccessibility = gen.checkAccessibility,
                .startListening = gen.startListening,
                .stopListening = gen.stopListening,
            },
        };
    }
};
