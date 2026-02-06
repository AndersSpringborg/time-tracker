const std = @import("std");

pub const ProjectEventMappingError = error{
    InvalidDuration,
    OutOfMemory,
};

/// Raw event candidate from storage. `project_id` is null for unmapped events.
pub const ProjectEventCandidate = struct {
    timestamp_ms: i64,
    duration_ms: i64,
    project_id: ?i64,
};

/// Event mapped to a concrete project and ready for weighted processing.
pub const MappedProjectEvent = struct {
    project_id: i64,
    timestamp_ms: i64,
    duration_ms: i64,
};

pub const MappingResult = struct {
    events: []MappedProjectEvent,
    source_event_count: usize,
    mapped_event_count: usize,
    excluded_unmapped_count: usize,
};

/// Domain policy: exclude unmapped events from project weighting.
pub const ProjectEventMapper = struct {
    pub fn mapToProjects(
        allocator: std.mem.Allocator,
        candidates: []const ProjectEventCandidate,
    ) ProjectEventMappingError!MappingResult {
        var mapped: std.ArrayListUnmanaged(MappedProjectEvent) = .{};
        defer mapped.deinit(allocator);

        var excluded_unmapped_count: usize = 0;

        for (candidates) |candidate| {
            if (candidate.duration_ms <= 0) return error.InvalidDuration;

            if (candidate.project_id) |project_id| {
                mapped.append(allocator, .{
                    .project_id = project_id,
                    .timestamp_ms = candidate.timestamp_ms,
                    .duration_ms = candidate.duration_ms,
                }) catch return error.OutOfMemory;
            } else {
                excluded_unmapped_count += 1;
            }
        }

        const mapped_event_count = mapped.items.len;

        return .{
            .events = mapped.toOwnedSlice(allocator) catch return error.OutOfMemory,
            .source_event_count = candidates.len,
            .mapped_event_count = mapped_event_count,
            .excluded_unmapped_count = excluded_unmapped_count,
        };
    }
};
