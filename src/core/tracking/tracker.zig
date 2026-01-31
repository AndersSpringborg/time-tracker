const std = @import("std");
const Event = @import("event").Event;

/// Generic repository interface using function pointers
pub fn Repository(comptime Context: type) type {
    return struct {
        context: Context,
        saveFn: *const fn (Context, Event, i64) void,

        pub fn save(self: @This(), event: Event, duration_ms: i64) void {
            self.saveFn(self.context, event, duration_ms);
        }
    };
}

pub const Tracker = struct {
    last_event: ?Event = null,
    last_app_name: [256]u8 = undefined,
    last_window_title: [512]u8 = undefined,
    last_wifi_ssid: [64]u8 = undefined,
    repo_context: *anyopaque,
    saveFn: *const fn (*anyopaque, Event, i64) void,

    pub fn init(repo: anytype) Tracker {
        const Ptr = @TypeOf(repo);
        const wrapper = struct {
            fn save(ctx: *anyopaque, event: Event, duration_ms: i64) void {
                const ptr: Ptr = @ptrCast(@alignCast(ctx));
                ptr.save(event, duration_ms);
            }
        };
        return Tracker{
            .repo_context = @ptrCast(repo),
            .saveFn = wrapper.save,
        };
    }

    pub fn onEvent(self: *Tracker, app: []const u8, title: []const u8, timestamp_ms: i64) void {
        self.onEventWithWifi(app, title, "", timestamp_ms);
    }

    pub fn onEventWithWifi(self: *Tracker, app: []const u8, title: []const u8, wifi: []const u8, timestamp_ms: i64) void {
        const new_event = Event{
            .timestamp_ms = timestamp_ms,
            .app_name = app,
            .window_title = title,
            .wifi_ssid = wifi,
        };

        if (self.last_event) |last| {
            // Skip if same as last event
            if (last.eql(new_event)) {
                return;
            }

            // Save the previous event with its duration
            const duration = last.durationUntil(new_event);
            self.saveFn(self.repo_context, last, duration);
        }

        // Store new event (copy strings to owned buffers)
        const app_len = @min(app.len, self.last_app_name.len);
        const title_len = @min(title.len, self.last_window_title.len);
        const wifi_len = @min(wifi.len, self.last_wifi_ssid.len);

        @memcpy(self.last_app_name[0..app_len], app[0..app_len]);
        @memcpy(self.last_window_title[0..title_len], title[0..title_len]);
        @memcpy(self.last_wifi_ssid[0..wifi_len], wifi[0..wifi_len]);

        self.last_event = Event{
            .timestamp_ms = timestamp_ms,
            .app_name = self.last_app_name[0..app_len],
            .window_title = self.last_window_title[0..title_len],
            .wifi_ssid = self.last_wifi_ssid[0..wifi_len],
        };
    }
};
