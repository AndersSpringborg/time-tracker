const std = @import("std");
const weighted = @import("time_weighted_project");

pub const TimeWeightedConfig = weighted.TimeWeightedConfig;
pub const BucketAssignment = weighted.BucketAssignment;
pub const ProjectInterval = weighted.ProjectInterval;
pub const UseCaseError = weighted.TimeWeightedProjectError;

/// Event input shape coming from persistence/query layers.
pub const ProjectEvent = struct {
    project_id: i64,
    timestamp_ms: i64,
    duration_ms: i64,
};

/// Application use case wrapper around the domain time-weighted projector.
pub const TimeWeightedProjectUseCase = struct {
    config: TimeWeightedConfig,

    pub fn init(config: TimeWeightedConfig) TimeWeightedProjectUseCase {
        return .{ .config = config };
    }

    pub fn computeBuckets(
        self: *const TimeWeightedProjectUseCase,
        allocator: std.mem.Allocator,
        events: []const ProjectEvent,
    ) UseCaseError![]BucketAssignment {
        const slices = try eventsToSlices(allocator, events);
        defer allocator.free(slices);

        return weighted.TimeWeightedProjector.computeBuckets(allocator, slices, self.config);
    }

    pub fn computeSmoothedBuckets(
        self: *const TimeWeightedProjectUseCase,
        allocator: std.mem.Allocator,
        events: []const ProjectEvent,
    ) UseCaseError![]BucketAssignment {
        const raw = try self.computeBuckets(allocator, events);
        defer allocator.free(raw);

        return weighted.TimeWeightedProjector.smoothBuckets(allocator, raw, self.config);
    }

    pub fn computeIntervals(
        self: *const TimeWeightedProjectUseCase,
        allocator: std.mem.Allocator,
        events: []const ProjectEvent,
    ) UseCaseError![]ProjectInterval {
        const smoothed = try self.computeSmoothedBuckets(allocator, events);
        defer allocator.free(smoothed);

        return weighted.TimeWeightedProjector.mergeBucketsToIntervals(allocator, smoothed);
    }

    fn eventsToSlices(allocator: std.mem.Allocator, events: []const ProjectEvent) UseCaseError![]weighted.ProjectSlice {
        var slices = allocator.alloc(weighted.ProjectSlice, events.len) catch {
            return UseCaseError.OutOfMemory;
        };

        for (events, 0..) |event, i| {
            if (event.duration_ms <= 0) {
                allocator.free(slices);
                return UseCaseError.InvalidRange;
            }

            slices[i] = weighted.ProjectSlice{
                .project_id = event.project_id,
                .start_ms = event.timestamp_ms,
                .end_ms = event.timestamp_ms + event.duration_ms,
            };
        }

        return slices;
    }
};
