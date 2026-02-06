const std = @import("std");

pub const TimeWeightedProjectError = error{
    InvalidConfig,
    InvalidRange,
    OutOfMemory,
};

/// A project-labeled time slice.
pub const ProjectSlice = struct {
    project_id: i64,
    start_ms: i64,
    end_ms: i64,

    pub fn durationMs(self: ProjectSlice) i64 {
        return self.end_ms - self.start_ms;
    }
};

/// Dominant project assignment for a fixed-size bucket.
pub const BucketAssignment = struct {
    bucket_start_ms: i64,
    bucket_end_ms: i64,
    dominant_project_id: ?i64,
    dominant_duration_ms: i64,
    total_tracked_ms: i64,
};

/// Final merged contiguous intervals after bucketing + smoothing.
pub const ProjectInterval = struct {
    project_id: i64,
    start_ms: i64,
    end_ms: i64,

    pub fn durationMs(self: ProjectInterval) i64 {
        return self.end_ms - self.start_ms;
    }
};

pub const TimeWeightedConfig = struct {
    bucket_size_ms: i64 = 5 * 60 * 1000,
    switch_threshold_ms: i64 = 10 * 60 * 1000,
};

const ProjectWeight = struct {
    project_id: i64,
    duration_ms: i64,
};

pub const TimeWeightedProjector = struct {
    /// Bucket raw slices and choose a dominant project per bucket.
    pub fn computeBuckets(
        allocator: std.mem.Allocator,
        slices: []const ProjectSlice,
        config: TimeWeightedConfig,
    ) TimeWeightedProjectError![]BucketAssignment {
        if (config.bucket_size_ms <= 0) return TimeWeightedProjectError.InvalidConfig;

        if (slices.len == 0) {
            return allocator.alloc(BucketAssignment, 0) catch return TimeWeightedProjectError.OutOfMemory;
        }

        var timeline_start = slices[0].start_ms;
        var timeline_end = slices[0].end_ms;

        for (slices) |slice| {
            if (slice.end_ms <= slice.start_ms) return TimeWeightedProjectError.InvalidRange;
            if (slice.start_ms < timeline_start) timeline_start = slice.start_ms;
            if (slice.end_ms > timeline_end) timeline_end = slice.end_ms;
        }

        const timeline_ms = timeline_end - timeline_start;
        const bucket_count_i64 = @divFloor(timeline_ms + config.bucket_size_ms - 1, config.bucket_size_ms);
        const bucket_count: usize = @intCast(bucket_count_i64);
        if (bucket_count == 0) {
            return allocator.alloc(BucketAssignment, 0) catch return TimeWeightedProjectError.OutOfMemory;
        }

        var bucket_weights = allocator.alloc(std.ArrayListUnmanaged(ProjectWeight), bucket_count) catch {
            return TimeWeightedProjectError.OutOfMemory;
        };
        defer allocator.free(bucket_weights);

        for (bucket_weights) |*weights| {
            weights.* = .{};
        }
        defer {
            for (bucket_weights) |*weights| {
                weights.deinit(allocator);
            }
        }

        for (slices) |slice| {
            var cursor = slice.start_ms;
            while (cursor < slice.end_ms) {
                const rel_ms = cursor - timeline_start;
                const bucket_idx: usize = @intCast(@divFloor(rel_ms, config.bucket_size_ms));
                const bucket_start = timeline_start + @as(i64, @intCast(bucket_idx)) * config.bucket_size_ms;
                const bucket_end = bucket_start + config.bucket_size_ms;
                const overlap_end = @min(slice.end_ms, bucket_end);
                const overlap_ms = overlap_end - cursor;

                try addWeight(allocator, &bucket_weights[bucket_idx], slice.project_id, overlap_ms);
                cursor = overlap_end;
            }
        }

        var buckets = allocator.alloc(BucketAssignment, bucket_count) catch {
            return TimeWeightedProjectError.OutOfMemory;
        };

        for (0..bucket_count) |i| {
            const bucket_start = timeline_start + @as(i64, @intCast(i)) * config.bucket_size_ms;
            const bucket_end = @min(bucket_start + config.bucket_size_ms, timeline_end);
            var total: i64 = 0;
            var dominant_duration: i64 = 0;
            var dominant_project: ?i64 = null;

            for (bucket_weights[i].items) |weight| {
                total += weight.duration_ms;
                if (weight.duration_ms > dominant_duration) {
                    dominant_duration = weight.duration_ms;
                    dominant_project = weight.project_id;
                } else if (weight.duration_ms == dominant_duration and dominant_project != null and weight.project_id < dominant_project.?) {
                    dominant_project = weight.project_id;
                }
            }

            buckets[i] = BucketAssignment{
                .bucket_start_ms = bucket_start,
                .bucket_end_ms = bucket_end,
                .dominant_project_id = dominant_project,
                .dominant_duration_ms = dominant_duration,
                .total_tracked_ms = total,
            };
        }

        return buckets;
    }

    /// Apply hysteresis so short project interruptions are rewritten to the
    /// current focused project until the switch threshold is exceeded.
    pub fn smoothBuckets(
        allocator: std.mem.Allocator,
        buckets: []const BucketAssignment,
        config: TimeWeightedConfig,
    ) TimeWeightedProjectError![]BucketAssignment {
        if (config.bucket_size_ms <= 0) return TimeWeightedProjectError.InvalidConfig;

        const out = allocator.alloc(BucketAssignment, buckets.len) catch {
            return TimeWeightedProjectError.OutOfMemory;
        };
        @memcpy(out, buckets);

        if (out.len == 0) return out;
        if (config.switch_threshold_ms <= 0) return out;

        var current: ?i64 = null;
        var pending_project: ?i64 = null;
        var pending_start: usize = 0;
        var pending_ms: i64 = 0;

        for (out, 0..) |*bucket, i| {
            const dominant = bucket.dominant_project_id;
            if (dominant == null) {
                pending_project = null;
                pending_ms = 0;
                continue;
            }

            if (current == null) {
                current = dominant;
                bucket.dominant_project_id = dominant;
                continue;
            }

            if (dominant.? == current.?) {
                pending_project = null;
                pending_ms = 0;
                bucket.dominant_project_id = current;
                continue;
            }

            if (pending_project != null and pending_project.? == dominant.?) {
                pending_ms += config.bucket_size_ms;
            } else {
                pending_project = dominant;
                pending_start = i;
                pending_ms = config.bucket_size_ms;
            }

            bucket.dominant_project_id = current;

            if (pending_ms > config.switch_threshold_ms) {
                current = pending_project;
                for (pending_start..i + 1) |j| {
                    out[j].dominant_project_id = current;
                }
                pending_project = null;
                pending_ms = 0;
            }
        }

        return out;
    }

    /// Merge adjacent buckets with the same dominant project into intervals.
    pub fn mergeBucketsToIntervals(
        allocator: std.mem.Allocator,
        buckets: []const BucketAssignment,
    ) TimeWeightedProjectError![]ProjectInterval {
        var intervals = allocator.alloc(ProjectInterval, buckets.len) catch {
            return TimeWeightedProjectError.OutOfMemory;
        };
        var count: usize = 0;

        var active_project: ?i64 = null;
        var active_start: i64 = 0;
        var active_end: i64 = 0;

        for (buckets) |bucket| {
            if (bucket.dominant_project_id == null) {
                if (active_project != null) {
                    intervals[count] = ProjectInterval{
                        .project_id = active_project.?,
                        .start_ms = active_start,
                        .end_ms = active_end,
                    };
                    count += 1;
                    active_project = null;
                }
                continue;
            }

            if (active_project == null) {
                active_project = bucket.dominant_project_id;
                active_start = bucket.bucket_start_ms;
                active_end = bucket.bucket_end_ms;
                continue;
            }

            if (active_project.? == bucket.dominant_project_id.? and bucket.bucket_start_ms <= active_end) {
                active_end = bucket.bucket_end_ms;
                continue;
            }

            intervals[count] = ProjectInterval{
                .project_id = active_project.?,
                .start_ms = active_start,
                .end_ms = active_end,
            };
            count += 1;

            active_project = bucket.dominant_project_id;
            active_start = bucket.bucket_start_ms;
            active_end = bucket.bucket_end_ms;
        }

        if (active_project != null) {
            intervals[count] = ProjectInterval{
                .project_id = active_project.?,
                .start_ms = active_start,
                .end_ms = active_end,
            };
            count += 1;
        }

        if (count == intervals.len) return intervals;

        const trimmed = allocator.alloc(ProjectInterval, count) catch {
            allocator.free(intervals);
            return TimeWeightedProjectError.OutOfMemory;
        };
        @memcpy(trimmed, intervals[0..count]);
        allocator.free(intervals);
        return trimmed;
    }

    fn addWeight(
        allocator: std.mem.Allocator,
        weights: *std.ArrayListUnmanaged(ProjectWeight),
        project_id: i64,
        overlap_ms: i64,
    ) TimeWeightedProjectError!void {
        if (overlap_ms <= 0) return;
        for (weights.items) |*item| {
            if (item.project_id == project_id) {
                item.duration_ms += overlap_ms;
                return;
            }
        }

        weights.append(allocator, .{
            .project_id = project_id,
            .duration_ms = overlap_ms,
        }) catch return TimeWeightedProjectError.OutOfMemory;
    }
};
