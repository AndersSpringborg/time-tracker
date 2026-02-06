const std = @import("std");
const weighted_usecase = @import("time_weighted_project_usecase");

const TimeWeightedProjectUseCase = weighted_usecase.TimeWeightedProjectUseCase;
const ProjectEvent = weighted_usecase.ProjectEvent;

test "TimeWeightedProjectUseCase computes smoothed intervals with hysteresis" {
    const minute = 60 * 1000;
    var usecase = TimeWeightedProjectUseCase.init(.{
        .bucket_size_ms = 5 * minute,
        .switch_threshold_ms = 10 * minute,
    });

    const events = [_]ProjectEvent{
        .{ .project_id = 1, .timestamp_ms = 0, .duration_ms = 30 * minute },
        .{ .project_id = 2, .timestamp_ms = 30 * minute, .duration_ms = 5 * minute },
        .{ .project_id = 1, .timestamp_ms = 35 * minute, .duration_ms = 25 * minute },
    };

    const intervals = try usecase.computeIntervals(std.testing.allocator, &events);
    defer std.testing.allocator.free(intervals);

    try std.testing.expectEqual(@as(usize, 1), intervals.len);
    try std.testing.expectEqual(@as(i64, 1), intervals[0].project_id);
    try std.testing.expectEqual(@as(i64, 0), intervals[0].start_ms);
    try std.testing.expectEqual(@as(i64, 60 * minute), intervals[0].end_ms);
}

test "TimeWeightedProjectUseCase rejects non-positive durations" {
    var usecase = TimeWeightedProjectUseCase.init(.{});
    const events = [_]ProjectEvent{
        .{ .project_id = 1, .timestamp_ms = 0, .duration_ms = 0 },
    };

    try std.testing.expectError(
        weighted_usecase.UseCaseError.InvalidRange,
        usecase.computeIntervals(std.testing.allocator, &events),
    );
}
