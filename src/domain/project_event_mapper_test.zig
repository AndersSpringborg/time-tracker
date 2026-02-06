const std = @import("std");
const mapper = @import("project_event_mapper.zig");

test "ProjectEventMapper excludes unmapped events and preserves mapped events" {
    const candidates = [_]mapper.ProjectEventCandidate{
        .{ .timestamp_ms = 1000, .duration_ms = 5000, .project_id = 10 },
        .{ .timestamp_ms = 6000, .duration_ms = 2000, .project_id = null },
        .{ .timestamp_ms = 8000, .duration_ms = 7000, .project_id = 11 },
    };

    const result = try mapper.ProjectEventMapper.mapToProjects(std.testing.allocator, &candidates);
    defer std.testing.allocator.free(result.events);

    try std.testing.expectEqual(@as(usize, 3), result.source_event_count);
    try std.testing.expectEqual(@as(usize, 2), result.mapped_event_count);
    try std.testing.expectEqual(@as(usize, 1), result.excluded_unmapped_count);

    try std.testing.expectEqual(@as(i64, 10), result.events[0].project_id);
    try std.testing.expectEqual(@as(i64, 11), result.events[1].project_id);
}

test "ProjectEventMapper rejects non-positive durations" {
    const candidates = [_]mapper.ProjectEventCandidate{
        .{ .timestamp_ms = 1000, .duration_ms = 0, .project_id = 10 },
    };

    try std.testing.expectError(
        mapper.ProjectEventMappingError.InvalidDuration,
        mapper.ProjectEventMapper.mapToProjects(std.testing.allocator, &candidates),
    );
}
