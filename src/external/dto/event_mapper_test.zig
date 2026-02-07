const std = @import("std");
const mapper = @import("event_mapper.zig");

test "event_mapper encode/decode roundtrip" {
    const allocator = std.testing.allocator;

    const input = mapper.EventDto{
        .timestamp_ms = 1_700_000_000_000,
        .app_name = "Code",
        .window_title = "main.zig",
        .wifi_ssid = "Office",
        .duration_ms = 2_500,
        .has_project_id = true,
        .project_id = 42,
        .has_activity_id = true,
        .activity_id = 77,
        .manually_mapped = true,
    };

    const payload = try mapper.encode(allocator, input);
    defer allocator.free(payload);

    const decoded = try mapper.decode(payload);
    try std.testing.expectEqual(input.timestamp_ms, decoded.timestamp_ms);
    try std.testing.expectEqualStrings(input.app_name, decoded.app_name);
    try std.testing.expectEqualStrings(input.window_title, decoded.window_title);
    try std.testing.expectEqualStrings(input.wifi_ssid, decoded.wifi_ssid);
    try std.testing.expectEqual(input.duration_ms, decoded.duration_ms);
    try std.testing.expectEqual(input.has_project_id, decoded.has_project_id);
    try std.testing.expectEqual(input.project_id, decoded.project_id);
    try std.testing.expectEqual(input.has_activity_id, decoded.has_activity_id);
    try std.testing.expectEqual(input.activity_id, decoded.activity_id);
    try std.testing.expectEqual(input.manually_mapped, decoded.manually_mapped);
}

test "event_mapper rejects missing required fields" {
    const allocator = std.testing.allocator;
    const input = mapper.EventDto{
        .timestamp_ms = 1,
        .app_name = "",
        .window_title = "title",
        .wifi_ssid = "",
    };
    try std.testing.expectError(error.MissingRequiredField, mapper.encode(allocator, input));
}

