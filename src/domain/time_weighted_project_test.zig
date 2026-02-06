const std = @import("std");
const weighted = @import("time_weighted_project.zig");

test "TimeWeightedProjector picks dominant project per bucket by overlap" {
    const slices = [_]weighted.ProjectSlice{
        .{ .project_id = 1, .start_ms = 0, .end_ms = 2 * 60 * 1000 },
        .{ .project_id = 2, .start_ms = 2 * 60 * 1000, .end_ms = 5 * 60 * 1000 },
    };

    const buckets = try weighted.TimeWeightedProjector.computeBuckets(std.testing.allocator, &slices, .{
        .bucket_size_ms = 5 * 60 * 1000,
        .switch_threshold_ms = 10 * 60 * 1000,
    });
    defer std.testing.allocator.free(buckets);

    try std.testing.expectEqual(@as(usize, 1), buckets.len);
    try std.testing.expectEqual(@as(?i64, 2), buckets[0].dominant_project_id);
}

test "TimeWeightedProjector rewrites short interruption to current project" {
    const minute = 60 * 1000;
    const slices = [_]weighted.ProjectSlice{
        .{ .project_id = 1, .start_ms = 0, .end_ms = 30 * minute },
        .{ .project_id = 2, .start_ms = 30 * minute, .end_ms = 35 * minute },
        .{ .project_id = 1, .start_ms = 35 * minute, .end_ms = 60 * minute },
    };

    const raw = try weighted.TimeWeightedProjector.computeBuckets(std.testing.allocator, &slices, .{
        .bucket_size_ms = 5 * minute,
        .switch_threshold_ms = 10 * minute,
    });
    defer std.testing.allocator.free(raw);

    const smooth = try weighted.TimeWeightedProjector.smoothBuckets(std.testing.allocator, raw, .{
        .bucket_size_ms = 5 * minute,
        .switch_threshold_ms = 10 * minute,
    });
    defer std.testing.allocator.free(smooth);

    try std.testing.expectEqual(@as(usize, 12), smooth.len);
    for (smooth) |bucket| {
        try std.testing.expectEqual(@as(?i64, 1), bucket.dominant_project_id);
    }
}

test "TimeWeightedProjector switches after threshold and rewrites pending buckets" {
    const minute = 60 * 1000;
    const slices = [_]weighted.ProjectSlice{
        .{ .project_id = 1, .start_ms = 0, .end_ms = 30 * minute },
        .{ .project_id = 2, .start_ms = 30 * minute, .end_ms = 45 * minute },
    };

    const raw = try weighted.TimeWeightedProjector.computeBuckets(std.testing.allocator, &slices, .{
        .bucket_size_ms = 5 * minute,
        .switch_threshold_ms = 10 * minute,
    });
    defer std.testing.allocator.free(raw);

    const smooth = try weighted.TimeWeightedProjector.smoothBuckets(std.testing.allocator, raw, .{
        .bucket_size_ms = 5 * minute,
        .switch_threshold_ms = 10 * minute,
    });
    defer std.testing.allocator.free(smooth);

    // Last three buckets should be project 2 after threshold is exceeded.
    try std.testing.expectEqual(@as(?i64, 2), smooth[6].dominant_project_id);
    try std.testing.expectEqual(@as(?i64, 2), smooth[7].dominant_project_id);
    try std.testing.expectEqual(@as(?i64, 2), smooth[8].dominant_project_id);
}

test "TimeWeightedProjector merges adjacent bucket assignments into intervals" {
    const buckets = [_]weighted.BucketAssignment{
        .{ .bucket_start_ms = 0, .bucket_end_ms = 300000, .dominant_project_id = 1, .dominant_duration_ms = 300000, .total_tracked_ms = 300000 },
        .{ .bucket_start_ms = 300000, .bucket_end_ms = 600000, .dominant_project_id = 1, .dominant_duration_ms = 300000, .total_tracked_ms = 300000 },
        .{ .bucket_start_ms = 600000, .bucket_end_ms = 900000, .dominant_project_id = 2, .dominant_duration_ms = 300000, .total_tracked_ms = 300000 },
        .{ .bucket_start_ms = 900000, .bucket_end_ms = 1200000, .dominant_project_id = null, .dominant_duration_ms = 0, .total_tracked_ms = 0 },
    };

    const intervals = try weighted.TimeWeightedProjector.mergeBucketsToIntervals(std.testing.allocator, &buckets);
    defer std.testing.allocator.free(intervals);

    try std.testing.expectEqual(@as(usize, 2), intervals.len);
    try std.testing.expectEqual(@as(i64, 1), intervals[0].project_id);
    try std.testing.expectEqual(@as(i64, 0), intervals[0].start_ms);
    try std.testing.expectEqual(@as(i64, 600000), intervals[0].end_ms);
    try std.testing.expectEqual(@as(i64, 2), intervals[1].project_id);
    try std.testing.expectEqual(@as(i64, 600000), intervals[1].start_ms);
    try std.testing.expectEqual(@as(i64, 900000), intervals[1].end_ms);
}
