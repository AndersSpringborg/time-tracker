const std = @import("std");

pub const Event = struct {
    timestamp_ms: i64,
    app_name: []const u8,
    window_title: []const u8,
    wifi_ssid: []const u8 = "",

    /// Calculate duration in milliseconds from this event until the next event
    pub fn durationUntil(self: Event, next: Event) i64 {
        return next.timestamp_ms - self.timestamp_ms;
    }

    /// Check if two events have the same app and window title (ignoring timestamp and wifi)
    pub fn eql(self: Event, other: Event) bool {
        return std.mem.eql(u8, self.app_name, other.app_name) and
            std.mem.eql(u8, self.window_title, other.window_title);
    }
};
