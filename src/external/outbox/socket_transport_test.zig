const std = @import("std");
const delivery = @import("delivery.zig");
const socket_transport = @import("socket_transport.zig");

const testing = std.testing;

/// A real Unix socket server answering one request with a canned reply, so the
/// transport is exercised over an actual socket rather than a stubbed stream.
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
        // Read the whole request before replying: closing mid-request makes the
        // client fail on its own write rather than on the reply under test.
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
    return std.fmt.bufPrint(buffer, "/tmp/tt-ipc-{x}.sock", .{std.crypto.random.int(u64)});
}

fn send(path: []const u8, body: []const u8) !delivery.Response {
    var transport = socket_transport.SocketTransport{ .path = path };
    const boundary = transport.transport();
    return boundary.send(boundary.ptr, body);
}

test "a committed batch is reported with its acknowledged sequence" {
    var buffer: [64]u8 = undefined;
    const path = try socketPath(&buffer);
    defer std.fs.cwd().deleteFile(path) catch {};
    const server = try CannedServer.start(path, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 44\r\n\r\n" ++
        "{\"acknowledged_sequence\":7,\"inserted\":2}\n   ");
    defer server.deinit();

    const response = try send(path, "{\"producer_id\":\"abc\",\"intervals\":[]}");
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expectEqual(@as(u64, 7), response.acknowledged_sequence);

    const request = server.finish();
    try testing.expect(std.mem.startsWith(u8, request, "POST /v1/events HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, request, "Content-Type: application/json\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, request, "Content-Length: 36\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, request, "{\"producer_id\":\"abc\",\"intervals\":[]}"));
}

test "a chunked reply is decoded" {
    var buffer: [64]u8 = undefined;
    const path = try socketPath(&buffer);
    defer std.fs.cwd().deleteFile(path) catch {};
    const server = try CannedServer.start(path, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "18\r\n{\"acknowledged_sequence\"\r\n4\r\n:12}\r\n0\r\n\r\n");
    defer server.deinit();

    const response = try send(path, "{}");
    try testing.expectEqual(@as(u64, 12), response.acknowledged_sequence);
    _ = server.finish();
}

test "a retryable error response is reported as retryable" {
    var buffer: [64]u8 = undefined;
    const path = try socketPath(&buffer);
    defer std.fs.cwd().deleteFile(path) catch {};
    const server = try CannedServer.start(path, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 54\r\n\r\n" ++
        "{\"error\":\"ingestion unavailable; retry\",\"retryable\":true}");
    defer server.deinit();

    const response = try send(path, "{}");
    try testing.expectEqual(@as(u16, 503), response.status);
    try testing.expect(response.retryable);
    try testing.expectEqual(@as(u64, 0), response.acknowledged_sequence);
    _ = server.finish();
}

test "a permanent error response is reported as not retryable" {
    var buffer: [64]u8 = undefined;
    const path = try socketPath(&buffer);
    defer std.fs.cwd().deleteFile(path) catch {};
    const server = try CannedServer.start(path, "HTTP/1.1 400 Bad Request\r\nContent-Length: 49\r\n\r\n" ++
        "{\"error\":\"expected one batch\",\"retryable\":false}\r\n");
    defer server.deinit();

    const response = try send(path, "{}");
    try testing.expectEqual(@as(u16, 400), response.status);
    try testing.expect(!response.retryable);
    _ = server.finish();
}

test "an unparsable reply is treated as a retryable transport failure" {
    var buffer: [64]u8 = undefined;
    const path = try socketPath(&buffer);
    defer std.fs.cwd().deleteFile(path) catch {};
    const server = try CannedServer.start(path, "not http at all");
    defer server.deinit();

    try testing.expectError(error.InvalidResponse, send(path, "{}"));
    _ = server.finish();
}

test "a missing backend socket fails instead of acknowledging" {
    var buffer: [64]u8 = undefined;
    const path = try socketPath(&buffer);
    try testing.expectError(error.FileNotFound, send(path, "{}"));
}

/// A server that accepts the connection and then never answers, standing in
/// for a wedged backend.
const SilentServer = struct {
    server: std.net.Server,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn start(path: []const u8) !*SilentServer {
        const address = try std.net.Address.initUnix(path);
        const self = try testing.allocator.create(SilentServer);
        errdefer testing.allocator.destroy(self);
        self.* = .{ .server = try address.listen(.{}), .thread = undefined };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn serve(self: *SilentServer) void {
        const connection = self.server.accept() catch return;
        defer connection.stream.close();
        while (!self.stop.load(.acquire)) {
            std.posix.nanosleep(0, 5 * std.time.ns_per_ms);
        }
    }

    fn deinit(self: *SilentServer) void {
        self.stop.store(true, .release);
        self.thread.join();
        self.server.deinit();
        testing.allocator.destroy(self);
    }
};

test "a backend that never answers fails fast instead of stalling the caller" {
    var buffer: [64]u8 = undefined;
    const path = try socketPath(&buffer);
    defer std.fs.cwd().deleteFile(path) catch {};
    const server = try SilentServer.start(path);
    defer server.deinit();

    var transport = socket_transport.SocketTransport{ .path = path, .timeout_ms = 100 };
    const boundary = transport.transport();

    const started_ns = std.time.nanoTimestamp();
    try testing.expectError(error.WouldBlock, boundary.send(boundary.ptr, "{\"intervals\":[]}"));
    const elapsed_ms = @divFloor(std.time.nanoTimestamp() - started_ns, std.time.ns_per_ms);

    try testing.expect(elapsed_ms >= 100);
    try testing.expect(elapsed_ms < 3_000);
}
