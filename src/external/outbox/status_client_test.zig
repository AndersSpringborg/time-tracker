const std = @import("std");
const testing = std.testing;
const status_client = @import("status_client.zig");

/// A real Unix socket server answering one request, so the client is exercised
/// over an actual socket rather than a stubbed stream.
const CannedServer = struct {
    server: std.net.Server,
    thread: std.Thread,
    reply: []const u8,
    request: [4096]u8 = undefined,
    request_len: usize = 0,

    fn start(path: []const u8, reply: []const u8) !*CannedServer {
        const address = try std.net.Address.initUnix(path);
        const self = try testing.allocator.create(CannedServer);
        errdefer testing.allocator.destroy(self);
        self.* = .{ .server = try address.listen(.{}), .thread = undefined, .reply = reply };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn serve(self: *CannedServer) void {
        const connection = self.server.accept() catch return;
        defer connection.stream.close();
        while (!self.requestComplete()) {
            const read = connection.stream.read(self.request[self.request_len..]) catch break;
            if (read == 0) break;
            self.request_len += read;
        }
        connection.stream.writeAll(self.reply) catch {};
    }

    fn requestComplete(self: *const CannedServer) bool {
        const request = self.request[0..self.request_len];
        const marker = "\r\n\r\n";
        const headers_end = std.mem.indexOf(u8, request, marker) orelse return false;
        const body_start = headers_end + marker.len;
        const field = "Content-Length: ";
        const at = std.mem.indexOf(u8, request[0..headers_end], field) orelse return true;
        const value = request[at + field.len ..];
        const value_end = std.mem.indexOfScalar(u8, value, '\r') orelse return false;
        const content_length = std.fmt.parseInt(usize, value[0..value_end], 10) catch return true;
        return request.len - body_start >= content_length;
    }

    fn finish(self: *CannedServer) []const u8 {
        self.thread.join();
        return self.request[0..self.request_len];
    }

    fn deinit(self: *CannedServer) void {
        self.server.deinit();
        testing.allocator.destroy(self);
    }
};

fn socketPath(buffer: []u8) ![]const u8 {
    // Unix socket paths are short on macOS, so stay out of long temp paths.
    return std.fmt.bufPrint(buffer, "/tmp/tt-status-{x}.sock", .{std.crypto.random.int(u64)});
}

test "a matched window is reported with its project and activity" {
    var buffer: [64]u8 = undefined;
    const path = try socketPath(&buffer);
    defer std.fs.cwd().deleteFile(path) catch {};
    const body = "{\"unmatched_count\":42,\"matched\":true,\"project\":\"Time Tracker\",\"activity\":\"Development\"}";
    var reply_buffer: [512]u8 = undefined;
    const server = try CannedServer.start(path, try std.fmt.bufPrint(
        &reply_buffer,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    ));
    defer server.deinit();

    var client = status_client.StatusClient{ .path = path };
    const snapshot = try client.fetch(.{ .app_name = "Ghostty", .window_title = "zig build test" });

    try testing.expectEqual(@as(i64, 42), snapshot.unmatched_count);
    try testing.expect(snapshot.matched);
    try testing.expectEqualStrings("Time Tracker", snapshot.project());
    try testing.expectEqualStrings("Development", snapshot.activity());

    const request = server.finish();
    try testing.expect(std.mem.startsWith(u8, request, "POST /v1/status HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, request, "\"app_name\":\"Ghostty\"") != null);
    try testing.expect(std.mem.indexOf(u8, request, "\"window_title\":\"zig build test\"") != null);
}

test "an unmatched window reports the count and no names" {
    var buffer: [64]u8 = undefined;
    const path = try socketPath(&buffer);
    defer std.fs.cwd().deleteFile(path) catch {};
    const body = "{\"unmatched_count\":7,\"matched\":false,\"project\":\"\",\"activity\":\"\"}";
    var reply_buffer: [512]u8 = undefined;
    const server = try CannedServer.start(path, try std.fmt.bufPrint(
        &reply_buffer,
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    ));
    defer server.deinit();

    var client = status_client.StatusClient{ .path = path };
    const snapshot = try client.fetch(.{ .app_name = "Mail", .window_title = "Inbox" });

    try testing.expectEqual(@as(i64, 7), snapshot.unmatched_count);
    try testing.expect(!snapshot.matched);
    try testing.expectEqualStrings("", snapshot.project());
    _ = server.finish();
}

test "window text with quotes and backslashes is escaped rather than corrupting the request" {
    var buffer: [64]u8 = undefined;
    const path = try socketPath(&buffer);
    defer std.fs.cwd().deleteFile(path) catch {};
    const body = "{\"unmatched_count\":0,\"matched\":false}";
    var reply_buffer: [512]u8 = undefined;
    const server = try CannedServer.start(path, try std.fmt.bufPrint(
        &reply_buffer,
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    ));
    defer server.deinit();

    var client = status_client.StatusClient{ .path = path };
    _ = try client.fetch(.{ .app_name = "say \"hi\"", .window_title = "C:\\path" });

    const request = server.finish();
    try testing.expect(std.mem.indexOf(u8, request, "\"app_name\":\"say \\\"hi\\\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, request, "\"window_title\":\"C:\\\\path\"") != null);
}

test "an error reply is surfaced instead of being read as a snapshot" {
    var buffer: [64]u8 = undefined;
    const path = try socketPath(&buffer);
    defer std.fs.cwd().deleteFile(path) catch {};
    const body = "{\"error\":\"status unavailable; retry\",\"retryable\":true}";
    var reply_buffer: [512]u8 = undefined;
    const server = try CannedServer.start(path, try std.fmt.bufPrint(
        &reply_buffer,
        "HTTP/1.1 503 Service Unavailable\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    ));
    defer server.deinit();

    var client = status_client.StatusClient{ .path = path };
    try testing.expectError(status_client.Error.StatusUnavailable, client.fetch(.{}));
    _ = server.finish();
}

test "a missing backend socket fails instead of reporting a stale snapshot" {
    var buffer: [64]u8 = undefined;
    const path = try socketPath(&buffer);

    var client = status_client.StatusClient{ .path = path };
    try testing.expectError(error.FileNotFound, client.fetch(.{}));
}

test "over-long window text is truncated rather than overflowing the request" {
    var buffer: [64]u8 = undefined;
    const path = try socketPath(&buffer);
    defer std.fs.cwd().deleteFile(path) catch {};
    const body = "{\"unmatched_count\":0,\"matched\":false}";
    var reply_buffer: [512]u8 = undefined;
    const server = try CannedServer.start(path, try std.fmt.bufPrint(
        &reply_buffer,
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    ));
    defer server.deinit();

    const long_title = [_]u8{'x'} ** 8192;
    var client = status_client.StatusClient{ .path = path };
    _ = try client.fetch(.{ .app_name = "Ghostty", .window_title = &long_title });
    _ = server.finish();
}
