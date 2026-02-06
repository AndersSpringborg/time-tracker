const std = @import("std");

/// Error type for query repository operations.
pub const QueryRepositoryError = error{
    QueryFailed,
    OutOfMemory,
};

/// Time range for filtering queries.
pub const TimeRange = enum {
    today,
    week,
    all,
};

/// Summary of time spent on an app.
pub const AppSummary = struct {
    app_name: []const u8,
    total_ms: i64,

    pub fn formatDuration(self: AppSummary, buf: []u8) []const u8 {
        return formatDurationMs(self.total_ms, buf);
    }
};

/// Details about a specific window title within an app.
pub const TitleDetail = struct {
    window_title: []const u8,
    total_ms: i64,
};

/// Event row with optional project mapping.
/// `project_id == null` means the event is currently unmapped.
pub const ProjectEventCandidate = struct {
    timestamp_ms: i64,
    duration_ms: i64,
    project_id: ?i64,
};

/// Format a duration in milliseconds to a human-readable string.
pub fn formatDurationMs(total_ms: i64, buf: []u8) []const u8 {
    const total_secs = @divFloor(total_ms, 1000);
    const hours = @divFloor(total_secs, 3600);
    const mins = @mod(@divFloor(total_secs, 60), 60);
    const secs = @mod(total_secs, 60);

    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}h {d}m {d}s", .{ hours, mins, secs }) catch "?";
    } else if (mins > 0) {
        return std.fmt.bufPrint(buf, "{d}m {d}s", .{ mins, secs }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch "?";
    }
}

/// Interface for querying time tracking summaries.
/// Implementations: DuckDbQueryRepository
pub const QueryRepository = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        getAppSummary: *const fn (*anyopaque, TimeRange) QueryRepositoryError![]AppSummary,
        getTitleDetails: *const fn (*anyopaque, []const u8, TimeRange) QueryRepositoryError![]TitleDetail,
        getTotalTrackedTime: *const fn (*anyopaque, TimeRange) QueryRepositoryError!i64,
        getProjectName: *const fn (*anyopaque, i64) QueryRepositoryError!?[]const u8,
        getProjectEventCandidates: *const fn (*anyopaque, TimeRange) QueryRepositoryError![]ProjectEventCandidate,
        freeAppSummaries: *const fn (*anyopaque, []AppSummary) void,
        freeTitleDetails: *const fn (*anyopaque, []TitleDetail) void,
        freeProjectEventCandidates: *const fn (*anyopaque, []ProjectEventCandidate) void,
        freeName: *const fn (*anyopaque, []const u8) void,
    };

    /// Get time summaries grouped by app.
    /// Caller must call freeAppSummaries() when done.
    pub fn getAppSummary(self: QueryRepository, range: TimeRange) QueryRepositoryError![]AppSummary {
        return self.vtable.getAppSummary(self.ptr, range);
    }

    /// Get title details for a specific app.
    /// Caller must call freeTitleDetails() when done.
    pub fn getTitleDetails(self: QueryRepository, app_name: []const u8, range: TimeRange) QueryRepositoryError![]TitleDetail {
        return self.vtable.getTitleDetails(self.ptr, app_name, range);
    }

    /// Get total tracked time for a time range.
    pub fn getTotalTrackedTime(self: QueryRepository, range: TimeRange) QueryRepositoryError!i64 {
        return self.vtable.getTotalTrackedTime(self.ptr, range);
    }

    /// Get the name of a project by ID.
    /// Caller must call freeName() when done.
    pub fn getProjectName(self: QueryRepository, project_id: i64) QueryRepositoryError!?[]const u8 {
        return self.vtable.getProjectName(self.ptr, project_id);
    }

    /// Get raw events with optional project mappings for weighted reporting.
    /// Caller must call freeProjectEventCandidates() when done.
    pub fn getProjectEventCandidates(self: QueryRepository, range: TimeRange) QueryRepositoryError![]ProjectEventCandidate {
        return self.vtable.getProjectEventCandidates(self.ptr, range);
    }

    /// Free app summaries returned by getAppSummary().
    pub fn freeAppSummaries(self: QueryRepository, summaries: []AppSummary) void {
        self.vtable.freeAppSummaries(self.ptr, summaries);
    }

    /// Free title details returned by getTitleDetails().
    pub fn freeTitleDetails(self: QueryRepository, details: []TitleDetail) void {
        self.vtable.freeTitleDetails(self.ptr, details);
    }

    /// Free project event candidates returned by getProjectEventCandidates().
    pub fn freeProjectEventCandidates(self: QueryRepository, candidates: []ProjectEventCandidate) void {
        self.vtable.freeProjectEventCandidates(self.ptr, candidates);
    }

    /// Free name returned by getProjectName().
    pub fn freeName(self: QueryRepository, name: []const u8) void {
        self.vtable.freeName(self.ptr, name);
    }

    /// Create a QueryRepository from any type that implements the required methods.
    pub fn init(impl: anytype) QueryRepository {
        const Impl = @TypeOf(impl);
        const impl_ptr = if (@typeInfo(Impl) == .pointer) impl else @as(*@TypeOf(impl.*), @ptrCast(@constCast(&impl)));

        const gen = struct {
            fn getAppSummary(ptr: *anyopaque, range: TimeRange) QueryRepositoryError![]AppSummary {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.getAppSummary(range);
            }

            fn getTitleDetails(ptr: *anyopaque, app_name: []const u8, range: TimeRange) QueryRepositoryError![]TitleDetail {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.getTitleDetails(app_name, range);
            }

            fn getTotalTrackedTime(ptr: *anyopaque, range: TimeRange) QueryRepositoryError!i64 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.getTotalTrackedTime(range);
            }

            fn getProjectName(ptr: *anyopaque, project_id: i64) QueryRepositoryError!?[]const u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.getProjectName(project_id);
            }

            fn getProjectEventCandidates(ptr: *anyopaque, range: TimeRange) QueryRepositoryError![]ProjectEventCandidate {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.getProjectEventCandidates(range);
            }

            fn freeAppSummaries(ptr: *anyopaque, summaries: []AppSummary) void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                self.freeAppSummaries(summaries);
            }

            fn freeTitleDetails(ptr: *anyopaque, details: []TitleDetail) void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                self.freeTitleDetails(details);
            }

            fn freeProjectEventCandidates(ptr: *anyopaque, candidates: []ProjectEventCandidate) void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                self.freeProjectEventCandidates(candidates);
            }

            fn freeName(ptr: *anyopaque, name: []const u8) void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                self.freeName(name);
            }
        };

        return .{
            .ptr = impl_ptr,
            .vtable = &.{
                .getAppSummary = gen.getAppSummary,
                .getTitleDetails = gen.getTitleDetails,
                .getTotalTrackedTime = gen.getTotalTrackedTime,
                .getProjectName = gen.getProjectName,
                .getProjectEventCandidates = gen.getProjectEventCandidates,
                .freeAppSummaries = gen.freeAppSummaries,
                .freeTitleDetails = gen.freeTitleDetails,
                .freeProjectEventCandidates = gen.freeProjectEventCandidates,
                .freeName = gen.freeName,
            },
        };
    }
};
