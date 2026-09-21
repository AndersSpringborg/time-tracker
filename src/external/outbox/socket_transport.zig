//! Transport that posts outbox batches to the backend's private Unix socket.
//!
//! Only the small subset of HTTP/1.1 the ingestion contract needs is spoken:
//! one bounded request per connection, closed by the server afterwards.
const std = @import("std");
const delivery = @import("delivery.zig");

pub const events_path = "/v1/events";
const max_response_len = 8 * 1024;

pub const Error = error{
    InvalidResponse,
    ResponseTooLarge,
};

pub const SocketTransport = struct {
    path: []const u8,

    const Self = @This();

    pub fn transport(self: *Self) delivery.Transport {
        return .{ .ptr = self, .send = sendBatch };
    }

    fn sendBatch(ptr: *anyopaque, body: []const u8) anyerror!delivery.Response {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const stream = try std.net.connectUnixSocket(self.path);
        defer stream.close();

        var header_buffer: [256]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buffer, "POST " ++ events_path ++ " HTTP/1.1\r\n" ++
            "Host: localhost\r\nContent-Type: application/json\r\n" ++
            "Content-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
        try stream.writeAll(header);
        try stream.writeAll(body);

        var response_buffer: [max_response_len]u8 = undefined;
        const response = try readResponse(stream, &response_buffer);
        return parseResponse(response);
    }
};

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

fn parseResponse(response: []const u8) !delivery.Response {
    if (!std.mem.startsWith(u8, response, "HTTP/1.")) return Error.InvalidResponse;
    const status_end = std.mem.indexOf(u8, response, "\r\n") orelse return Error.InvalidResponse;
    var status_parts = std.mem.tokenizeScalar(u8, response[0..status_end], ' ');
    _ = status_parts.next() orelse return Error.InvalidResponse;
    const status_text = status_parts.next() orelse return Error.InvalidResponse;
    const status = std.fmt.parseInt(u16, status_text, 10) catch return Error.InvalidResponse;

    const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return Error.InvalidResponse;
    const headers = response[0..header_end];
    var body = response[header_end + 4 ..];
    var decoded_buffer: [max_response_len]u8 = undefined;
    if (containsHeader(headers, "transfer-encoding: chunked")) {
        body = try decodeChunked(body, &decoded_buffer);
    }

    return delivery.Response{
        .status = status,
        .retryable = status != 200 and readRetryable(body),
        .acknowledged_sequence = if (status == 200) try readAcknowledgedSequence(body) else 0,
    };
}

fn containsHeader(headers: []const u8, needle: []const u8) bool {
    var lower_buffer: [1024]u8 = undefined;
    if (headers.len > lower_buffer.len) return false;
    const lower = std.ascii.lowerString(lower_buffer[0..headers.len], headers);
    return std.mem.indexOf(u8, lower, needle) != null;
}

fn decodeChunked(body: []const u8, out: []u8) ![]const u8 {
    var offset: usize = 0;
    var length: usize = 0;
    while (true) {
        const line_end = std.mem.indexOfPos(u8, body, offset, "\r\n") orelse return Error.InvalidResponse;
        const size = std.fmt.parseInt(usize, body[offset..line_end], 16) catch return Error.InvalidResponse;
        if (size == 0) return out[0..length];
        const start = line_end + 2;
        if (start + size > body.len or length + size > out.len) return Error.InvalidResponse;
        @memcpy(out[length..][0..size], body[start..][0..size]);
        length += size;
        offset = start + size + 2;
    }
}

/// The reply is small and fixed-shape, so it is scanned rather than parsed with
/// an allocator: delivery must not fail because memory was unavailable.
fn readAcknowledgedSequence(body: []const u8) !u64 {
    const field = "\"acknowledged_sequence\":";
    const start = std.mem.indexOf(u8, body, field) orelse return Error.InvalidResponse;
    var cursor = start + field.len;
    while (cursor < body.len and body[cursor] == ' ') cursor += 1;
    var end = cursor;
    while (end < body.len and std.ascii.isDigit(body[end])) end += 1;
    if (end == cursor) return Error.InvalidResponse;
    return std.fmt.parseInt(u64, body[cursor..end], 10) catch Error.InvalidResponse;
}

fn readRetryable(body: []const u8) bool {
    const field = "\"retryable\":";
    const start = std.mem.indexOf(u8, body, field) orelse return false;
    var cursor = start + field.len;
    while (cursor < body.len and body[cursor] == ' ') cursor += 1;
    return std.mem.startsWith(u8, body[cursor..], "true");
}
