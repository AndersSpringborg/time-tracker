const std = @import("std");
const query_repo = @import("query_repository");
const mapper = @import("project_event_mapper");
const weighted_usecase = @import("time_weighted_project_usecase");

const QueryRepository = query_repo.QueryRepository;
const TimeRange = query_repo.TimeRange;
const ProjectEventCandidate = query_repo.ProjectEventCandidate;

pub const WeightedReportConfig = struct {
    bucket_size_ms: i64 = 5 * 60 * 1000,
    switch_threshold_ms: i64 = 10 * 60 * 1000,
};

pub const WeightedProjectInterval = struct {
    project_id: i64,
    start_ms: i64,
    end_ms: i64,
    duration_ms: i64,
};

pub const WeightedProjectTotal = struct {
    project_id: i64,
    total_ms: i64,
};

pub const WeightedProjectReport = struct {
    intervals: []WeightedProjectInterval,
    totals: []WeightedProjectTotal,
    source_event_count: usize,
    mapped_event_count: usize,
    excluded_unmapped_count: usize,

    pub fn deinit(self: *WeightedProjectReport, allocator: std.mem.Allocator) void {
        allocator.free(self.intervals);
        allocator.free(self.totals);
    }
};

pub const WeightedReportError = query_repo.QueryRepositoryError || mapper.ProjectEventMappingError || weighted_usecase.UseCaseError || error{
    InvalidConfig,
    OutOfMemory,
};

/// Use case that maps tracked events to projects and applies weighted smoothing.
pub const ProjectWeightedReportUseCase = struct {
    query_repository: QueryRepository,
    config: WeightedReportConfig,

    pub fn init(query_repository_: QueryRepository, config: WeightedReportConfig) ProjectWeightedReportUseCase {
        return .{
            .query_repository = query_repository_,
            .config = config,
        };
    }

    pub fn run(
        self: *const ProjectWeightedReportUseCase,
        allocator: std.mem.Allocator,
        range: TimeRange,
    ) WeightedReportError!WeightedProjectReport {
        if (self.config.bucket_size_ms <= 0 or self.config.switch_threshold_ms <= 0) {
            return error.InvalidConfig;
        }

        const candidates = try self.query_repository.getProjectEventCandidates(range);
        defer self.query_repository.freeProjectEventCandidates(candidates);

        const domain_candidates = try toDomainCandidates(allocator, candidates);
        defer allocator.free(domain_candidates);

        const mapped = try mapper.ProjectEventMapper.mapToProjects(allocator, domain_candidates);
        defer allocator.free(mapped.events);

        const events = try toWeightedEvents(allocator, mapped.events);
        defer allocator.free(events);

        var time_weighted = weighted_usecase.TimeWeightedProjectUseCase.init(.{
            .bucket_size_ms = self.config.bucket_size_ms,
            .switch_threshold_ms = self.config.switch_threshold_ms,
        });

        const computed_intervals = try time_weighted.computeIntervals(allocator, events);
        defer allocator.free(computed_intervals);

        const intervals = allocator.alloc(WeightedProjectInterval, computed_intervals.len) catch {
            return error.OutOfMemory;
        };

        for (computed_intervals, 0..) |interval, i| {
            intervals[i] = .{
                .project_id = interval.project_id,
                .start_ms = interval.start_ms,
                .end_ms = interval.end_ms,
                .duration_ms = interval.durationMs(),
            };
        }

        const totals = try aggregateTotals(allocator, intervals);

        return .{
            .intervals = intervals,
            .totals = totals,
            .source_event_count = mapped.source_event_count,
            .mapped_event_count = mapped.mapped_event_count,
            .excluded_unmapped_count = mapped.excluded_unmapped_count,
        };
    }

    fn toDomainCandidates(
        allocator: std.mem.Allocator,
        candidates: []const ProjectEventCandidate,
    ) WeightedReportError![]mapper.ProjectEventCandidate {
        const out = allocator.alloc(mapper.ProjectEventCandidate, candidates.len) catch {
            return error.OutOfMemory;
        };

        for (candidates, 0..) |candidate, i| {
            out[i] = .{
                .timestamp_ms = candidate.timestamp_ms,
                .duration_ms = candidate.duration_ms,
                .project_id = candidate.project_id,
            };
        }

        return out;
    }

    fn toWeightedEvents(
        allocator: std.mem.Allocator,
        events: []const mapper.MappedProjectEvent,
    ) WeightedReportError![]weighted_usecase.ProjectEvent {
        const out = allocator.alloc(weighted_usecase.ProjectEvent, events.len) catch {
            return error.OutOfMemory;
        };

        for (events, 0..) |event, i| {
            out[i] = .{
                .project_id = event.project_id,
                .timestamp_ms = event.timestamp_ms,
                .duration_ms = event.duration_ms,
            };
        }

        return out;
    }

    fn aggregateTotals(
        allocator: std.mem.Allocator,
        intervals: []const WeightedProjectInterval,
    ) WeightedReportError![]WeightedProjectTotal {
        var totals: std.ArrayListUnmanaged(WeightedProjectTotal) = .{};
        defer totals.deinit(allocator);

        for (intervals) |interval| {
            var found = false;
            for (totals.items) |*total| {
                if (total.project_id == interval.project_id) {
                    total.total_ms += interval.duration_ms;
                    found = true;
                    break;
                }
            }

            if (!found) {
                totals.append(allocator, .{
                    .project_id = interval.project_id,
                    .total_ms = interval.duration_ms,
                }) catch return error.OutOfMemory;
            }
        }

        std.mem.sort(WeightedProjectTotal, totals.items, {}, struct {
            fn lessThan(_: void, lhs: WeightedProjectTotal, rhs: WeightedProjectTotal) bool {
                if (lhs.total_ms == rhs.total_ms) return lhs.project_id < rhs.project_id;
                return lhs.total_ms > rhs.total_ms;
            }
        }.lessThan);

        return totals.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }
};
