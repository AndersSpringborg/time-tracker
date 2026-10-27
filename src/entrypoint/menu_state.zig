//! The menubar's view of the world, cached in memory.
//!
//! Opening the menu must never wait on the backend or the database, so the
//! worker keeps the last snapshot here and renders it immediately. A refresh
//! that fails leaves the previous snapshot standing and marks it stale, which
//! is more useful to read than a blank menu.
const std = @import("std");
const status_client = @import("status_client");

/// Scratch space a caller lends to `window`, so reading the focused window
/// copies out of the lock rather than handing out a pointer into it.
pub const WindowText = struct {
    app_buf: [status_client.max_window_text]u8 = undefined,
    title_buf: [status_client.max_window_text]u8 = undefined,
};

pub const MenuState = struct {
    mutex: std.Thread.Mutex = .{},

    app_buf: [status_client.max_window_text]u8 = undefined,
    app_len: usize = 0,
    title_buf: [status_client.max_window_text]u8 = undefined,
    title_len: usize = 0,

    cached: status_client.Snapshot = .{},
    stale: bool = true,

    const Self = @This();

    /// Record the focused window. Called from the AppKit callback, so it does
    /// nothing but copy: no allocation, no I/O, no backend.
    pub fn setWindow(self: *Self, app_name: []const u8, window_title: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.app_len = copyTruncated(&self.app_buf, app_name);
        self.title_len = copyTruncated(&self.title_buf, window_title);
    }

    pub fn window(self: *Self, into: *WindowText) status_client.Window {
        self.mutex.lock();
        defer self.mutex.unlock();
        @memcpy(into.app_buf[0..self.app_len], self.app_buf[0..self.app_len]);
        @memcpy(into.title_buf[0..self.title_len], self.title_buf[0..self.title_len]);
        return .{
            .app_name = into.app_buf[0..self.app_len],
            .window_title = into.title_buf[0..self.title_len],
        };
    }

    pub fn recordSnapshot(self: *Self, fresh: status_client.Snapshot) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cached = fresh;
        self.stale = false;
    }

    /// Keep what we last knew; only note that it is no longer current.
    pub fn recordFailure(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stale = true;
    }

    pub fn snapshot(self: *Self) status_client.Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cached;
    }

    pub fn isStale(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stale;
    }
};

fn copyTruncated(buffer: []u8, text: []const u8) usize {
    const length = @min(text.len, buffer.len);
    @memcpy(buffer[0..length], text[0..length]);
    return length;
}
