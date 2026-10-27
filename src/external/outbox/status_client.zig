//! Reads the menubar snapshot from the backend's private IPC socket.
//!
//! The menu must never wait on I/O, so the worker polls this on a background
//! thread and renders whatever it last learned. Nothing here allocates: a
//! failed refresh must leave the previous snapshot standing, not crash the
//! worker or block capture.
const std = @import("std");

pub const status_path = "/v1/status";

/// Bounds on what the menu will show. Longer text is truncated rather than
/// growing the request, because the menu cannot display it anyway.
pub const max_window_text = 512;
pub const max_name_len = 128;
const max_response_len = 8 * 1024;
const max_request_len = 4 * max_window_text + 256;

pub const Error = error{
    InvalidResponse,
    ResponseTooLarge,
    /// The backend answered, but could not produce a snapshot.
    StatusUnavailable,
};

pub const Window = struct {
    app_name: []const u8 = "",
    window_title: []const u8 = "",
};

/// An immutable snapshot the menu can render without touching the backend.
pub const Snapshot = struct {
    unmatched_count: i64 = 0,
    matched: bool = false,
    project_buf: [max_name_len]u8 = undefined,
    project_len: usize = 0,
    activity_buf: [max_name_len]u8 = undefined,
    activity_len: usize = 0,

    pub fn project(self: *const Snapshot) []const u8 {
        return self.project_buf[0..self.project_len];
    }

    pub fn activity(self: *const Snapshot) []const u8 {
        return self.activity_buf[0..self.activity_len];
    }
};

pub const StatusClient = struct {
    path: []const u8,
    /// Bounded so a wedged backend delays the menu refresh, nothing else.
    timeout_ms: u32 = 2_000,

    const Self = @This();

    pub fn fetch(self: *Self, window: Window) !Snapshot {
        var request_buffer: [max_request_len]u8 = undefined;
        const body = try encodeRequest(&request_buffer, window);

        const stream = try std.net.connectUnixSocket(self.path);
        defer stream.close();
        try setTimeouts(stream, self.timeout_ms);

        var header_buffer: [256]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buffer, "POST " ++ status_path ++ " HTTP/1.1\r\n" ++
            "Host: localhost\r\nContent-Type: application/json\r\n" ++
            "Content-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
        try stream.writeAll(header);
        try stream.writeAll(body);

        var response_buffer: [max_response_len]u8 = undefined;
        return parseResponse(try readResponse(stream, &response_buffer));
    }
};

fn encodeRequest(buffer: []u8, window: Window) ![]u8 {
    var writer = std.Io.Writer.fixed(buffer);
    var stringify = std.json.Stringify{ .writer = &writer };
    try stringify.write(.{
        .app_name = truncate(window.app_name),
        .window_title = truncate(window.window_title),
    });
    return writer.buffered();
}

fn truncate(text: []const u8) []const u8 {
    return text[0..@min(text.len, max_window_text)];
}

fn setTimeouts(stream: std.net.Stream, timeout_ms: u32) !void {
    const timeout = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    const bytes = std.mem.asBytes(&timeout);
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, bytes);
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, bytes);
}

fn readResponse(stream: std.net.Stream, buffer: []u8) ![]const u8 {
    var length: usize = 0;
    while (length < buffer.len) {
        const read = try stream.read(buffer[length..]);
        if (read == 0) break;
        length += read;
    }
    if (length == buffer.len) return Error.ResponseTooLarge;
    return buffer[0..length];
}

fn parseResponse(response: []const u8) !Snapshot {
    if (!std.mem.startsWith(u8, response, "HTTP/1.")) return Error.InvalidResponse;
    const status_end = std.mem.indexOf(u8, response, "\r\n") orelse return Error.InvalidResponse;
    var status_parts = std.mem.tokenizeScalar(u8, response[0..status_end], ' ');
    _ = status_parts.next() orelse return Error.InvalidResponse;
    const status_text = status_parts.next() orelse return Error.InvalidResponse;
    const status = std.fmt.parseInt(u16, status_text, 10) catch return Error.InvalidResponse;
    if (status != 200) return Error.StatusUnavailable;

    const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return Error.InvalidResponse;
    const body = response[header_end + 4 ..];

    var snapshot = Snapshot{};
    snapshot.unmatched_count = readInt(body, "\"unmatched_count\":") orelse return Error.InvalidResponse;
    snapshot.matched = readBool(body, "\"matched\":");
    snapshot.project_len = readString(body, "\"project\":", &snapshot.project_buf);
    snapshot.activity_len = readString(body, "\"activity\":", &snapshot.activity_buf);
    return snapshot;
}

/// The reply is small and fixed-shape, so it is scanned rather than parsed with
/// an allocator: a menu refresh must not fail because memory was unavailable.
fn fieldStart(body: []const u8, field: []const u8) ?usize {
    const at = std.mem.indexOf(u8, body, field) orelse return null;
    var cursor = at + field.len;
    while (cursor < body.len and body[cursor] == ' ') cursor += 1;
    return cursor;
}

fn readInt(body: []const u8, field: []const u8) ?i64 {
    const cursor = fieldStart(body, field) orelse return null;
    var end = cursor;
    if (end < body.len and body[end] == '-') end += 1;
    while (end < body.len and std.ascii.isDigit(body[end])) end += 1;
    if (end == cursor) return null;
    return std.fmt.parseInt(i64, body[cursor..end], 10) catch null;
}

fn readBool(body: []const u8, field: []const u8) bool {
    const cursor = fieldStart(body, field) orelse return false;
    return std.mem.startsWith(u8, body[cursor..], "true");
}

/// Copies a JSON string field into out, undoing the escapes the backend's
/// encoder can produce for project and activity titles.
fn readString(body: []const u8, field: []const u8, out: []u8) usize {
    const cursor = fieldStart(body, field) orelse return 0;
    if (cursor >= body.len or body[cursor] != '"') return 0;

    var read = cursor + 1;
    var written: usize = 0;
    while (read < body.len and written < out.len) {
        const char = body[read];
        if (char == '"') break;
        if (char != '\\') {
            out[written] = char;
            written += 1;
            read += 1;
            continue;
        }
        read += 1;
        if (read >= body.len) break;
        out[written] = switch (body[read]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'b' => 8,
            'f' => 12,
            // \uXXXX is left as the literal characters rather than decoded:
            // the menu is better off showing them than showing nothing.
            else => |escaped| escaped,
        };
        written += 1;
        read += 1;
    }
    return written;
}
