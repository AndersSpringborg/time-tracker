const std = @import("std");
const query_repo = @import("query_repository");
const weighted_report = @import("project_weighted_report_usecase");

const QueryRepository = query_repo.QueryRepository;
const QueryRepositoryError = query_repo.QueryRepositoryError;
const TimeRange = query_repo.TimeRange;
const AppSummary = query_repo.AppSummary;
const TitleDetail = query_repo.TitleDetail;
const ProjectEventCandidate = query_repo.ProjectEventCandidate;

const ProjectWeightedReportUseCase = weighted_report.ProjectWeightedReportUseCase;
const WeightedReportError = weighted_report.WeightedReportError;

const FakeQueryRepository = struct {
    allocator: std.mem.Allocator,
    candidates: []const ProjectEventCandidate,

    pub fn init(allocator: std.mem.Allocator, candidates: []const ProjectEventCandidate) FakeQueryRepository {
        return .{
            .allocator = allocator,
            .candidates = candidates,
        };
    }

    pub fn getAppSummary(_: *FakeQueryRepository, _: TimeRange) QueryRepositoryError![]AppSummary {
        return &[_]AppSummary{};
    }

    pub fn getTitleDetails(_: *FakeQueryRepository, _: []const u8, _: TimeRange) QueryRepositoryError![]TitleDetail {
        return &[_]TitleDetail{};
    }

    pub fn getTotalTrackedTime(_: *FakeQueryRepository, _: TimeRange) QueryRepositoryError!i64 {
        return 0;
    }

    pub fn getProjectName(_: *FakeQueryRepository, _: i64) QueryRepositoryError!?[]const u8 {
        return null;
    }

    pub fn getProjectEventCandidates(self: *FakeQueryRepository, _: TimeRange) QueryRepositoryError![]ProjectEventCandidate {
        const out = self.allocator.alloc(ProjectEventCandidate, self.candidates.len) catch {
            return error.OutOfMemory;
        };
        @memcpy(out, self.candidates);
        return out;
    }

    pub fn freeAppSummaries(_: *FakeQueryRepository, _: []AppSummary) void {}
    pub fn freeTitleDetails(_: *FakeQueryRepository, _: []TitleDetail) void {}
    pub fn freeName(_: *FakeQueryRepository, _: []const u8) void {}

    pub fn freeProjectEventCandidates(self: *FakeQueryRepository, candidates: []ProjectEventCandidate) void {
        self.allocator.free(candidates);
    }

    pub fn repository(self: *FakeQueryRepository) QueryRepository {
        return QueryRepository.init(self);
    }
};

test "ProjectWeightedReportUseCase maps events to projects and excludes unmapped rows" {
    const minute: i64 = 60 * 1000;
    const candidates = [_]ProjectEventCandidate{
        .{ .timestamp_ms = 0, .duration_ms = 30 * minute, .project_id = 1 },
        .{ .timestamp_ms = 30 * minute, .duration_ms = 1 * minute, .project_id = null },
        .{ .timestamp_ms = 31 * minute, .duration_ms = 5 * minute, .project_id = 2 },
        .{ .timestamp_ms = 36 * minute, .duration_ms = 24 * minute, .project_id = 1 },
    };

    var repo = FakeQueryRepository.init(std.testing.allocator, &candidates);
    var usecase = ProjectWeightedReportUseCase.init(repo.repository(), .{
        .bucket_size_ms = 5 * minute,
        .switch_threshold_ms = 10 * minute,
    });

    var report = try usecase.run(std.testing.allocator, .all);
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), report.source_event_count);
    try std.testing.expectEqual(@as(usize, 3), report.mapped_event_count);
    try std.testing.expectEqual(@as(usize, 1), report.excluded_unmapped_count);

    try std.testing.expectEqual(@as(usize, 1), report.intervals.len);
    try std.testing.expectEqual(@as(i64, 1), report.intervals[0].project_id);
    try std.testing.expectEqual(@as(i64, 0), report.intervals[0].start_ms);
    try std.testing.expectEqual(@as(i64, 60 * minute), report.intervals[0].end_ms);

    try std.testing.expectEqual(@as(usize, 1), report.totals.len);
    try std.testing.expectEqual(@as(i64, 1), report.totals[0].project_id);
    try std.testing.expectEqual(@as(i64, 60 * minute), report.totals[0].total_ms);
}

test "ProjectWeightedReportUseCase validates config values" {
    const candidates = [_]ProjectEventCandidate{};
    var repo = FakeQueryRepository.init(std.testing.allocator, &candidates);
    var usecase = ProjectWeightedReportUseCase.init(repo.repository(), .{
        .bucket_size_ms = 0,
        .switch_threshold_ms = 10 * 60 * 1000,
    });

    try std.testing.expectError(
        WeightedReportError.InvalidConfig,
        usecase.run(std.testing.allocator, .all),
    );
}
