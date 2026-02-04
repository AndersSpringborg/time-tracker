const std = @import("std");
const migrations = @import("migrations");
pub const c = migrations.c;
const scoring = @import("domain_scoring");
const SuggestionScorer = scoring.SuggestionScorer;
const ScoredSuggestion = scoring.ScoredSuggestion;

pub const SuggestionError = error{
    QueryFailed,
    OutOfMemory,
};

/// A suggestion for mapping an event
pub const Suggestion = struct {
    activity_id: i64,
    kind_id: i64,
    display_path: []const u8, // "Customer > Project > Phase > Activity > Kind"
    score: u32,
    is_active_project: bool,
    reason: []const u8, // "Matched rule" or "Similar to 5 events" etc.
};

/// Candidate from rules or past mappings
const Candidate = struct {
    activity_id: i64,
    kind_id: i64,
    project_id: i64,
    app_pattern: []const u8,
    title_pattern: []const u8,
    times_used: u32,
    last_used_days: u32,
    reason: []const u8,
    // Buffers
    app_pattern_buf: [256]u8 = undefined,
    title_pattern_buf: [256]u8 = undefined,
};

/// Engine that combines rules, history, and context to generate suggestions
pub const SuggestionEngine = struct {
    conn: c.duckdb_connection,
    allocator: std.mem.Allocator,
    scorer: SuggestionScorer,

    pub fn init(conn: c.duckdb_connection, allocator: std.mem.Allocator) SuggestionEngine {
        return .{
            .conn = conn,
            .allocator = allocator,
            .scorer = SuggestionScorer.init(.{}),
        };
    }

    /// Get top N suggestions for a given app/title
    pub fn getSuggestions(
        self: *SuggestionEngine,
        app_name: []const u8,
        window_title: []const u8,
        max_results: usize,
    ) SuggestionError![]Suggestion {
        // Get active project IDs
        const active_projects = try self.getActiveProjectIds();
        defer self.allocator.free(active_projects);

        // Get candidates from rules
        const candidates = try self.getCandidatesFromRules();
        defer self.allocator.free(candidates);

        if (candidates.len == 0) {
            return self.allocator.alloc(Suggestion, 0) catch return SuggestionError.OutOfMemory;
        }

        // Score each candidate
        var scored = self.allocator.alloc(ScoredSuggestion, candidates.len) catch {
            return SuggestionError.OutOfMemory;
        };
        defer self.allocator.free(scored);

        var valid_count: usize = 0;
        for (candidates, 0..) |candidate, i| {
            const is_active = self.isInActiveProjects(candidate.project_id, active_projects);

            const score = self.scorer.calculateScore(.{
                .app_name = app_name,
                .window_title = window_title,
                .candidate_app_pattern = candidate.app_pattern,
                .candidate_title_pattern = candidate.title_pattern,
                .times_used = candidate.times_used,
                .recency_days = candidate.last_used_days,
                .is_active_project = is_active,
            });

            if (score > 0) {
                scored[valid_count] = .{
                    .id = @intCast(i),
                    .score = score,
                };
                valid_count += 1;
            }
        }

        if (valid_count == 0) {
            return self.allocator.alloc(Suggestion, 0) catch return SuggestionError.OutOfMemory;
        }

        // Sort and get top N
        const valid_scored = scored[0..valid_count];
        const top = self.scorer.topN(valid_scored, max_results);

        // Build suggestions with display paths
        var suggestions = self.allocator.alloc(Suggestion, top.len) catch {
            return SuggestionError.OutOfMemory;
        };
        errdefer {
            for (suggestions[0..]) |s| {
                self.allocator.free(s.display_path);
            }
            self.allocator.free(suggestions);
        }

        for (top, 0..) |s, idx| {
            const candidate = candidates[s.id];
            const display_path = try self.getDisplayPath(candidate.activity_id, candidate.kind_id);

            suggestions[idx] = .{
                .activity_id = candidate.activity_id,
                .kind_id = candidate.kind_id,
                .display_path = display_path,
                .score = s.score,
                .is_active_project = self.isInActiveProjects(candidate.project_id, active_projects),
                .reason = candidate.reason,
            };
        }

        return suggestions;
    }

    fn getActiveProjectIds(self: *SuggestionEngine) SuggestionError![]i64 {
        var result: c.duckdb_result = undefined;
        const sql = "SELECT project_id FROM project_assignments WHERE ended_at IS NULL";

        if (c.duckdb_query(self.conn, sql, &result) == c.DuckDBError) {
            return SuggestionError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var ids = self.allocator.alloc(i64, row_count) catch {
            return SuggestionError.OutOfMemory;
        };

        for (0..row_count) |i| {
            const idx: c.idx_t = @intCast(i);
            ids[i] = c.duckdb_value_int64(&result, 0, idx);
        }

        return ids;
    }

    fn getCandidatesFromRules(self: *SuggestionEngine) SuggestionError![]Candidate {
        var result: c.duckdb_result = undefined;
        // Get rules with their project IDs by joining through hierarchy
        const sql =
            \\SELECT 
            \\  r.activity_id, r.kind_id,
            \\  p.project_id,
            \\  r.app_pattern, r.title_pattern,
            \\  0 as times_used, 0 as last_used_days
            \\FROM mapping_rules r
            \\JOIN activities a ON r.activity_id = a.activity_id
            \\JOIN phases ph ON a.phase_id = ph.phase_id
            \\JOIN projects p ON ph.project_id = p.project_id
            \\WHERE r.activity_id IS NOT NULL AND r.kind_id IS NOT NULL
            \\ORDER BY r.priority DESC
            \\LIMIT 50
        ;

        if (c.duckdb_query(self.conn, sql, &result) == c.DuckDBError) {
            return SuggestionError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var candidates = self.allocator.alloc(Candidate, row_count) catch {
            return SuggestionError.OutOfMemory;
        };

        for (0..row_count) |i| {
            const idx: c.idx_t = @intCast(i);

            candidates[i] = Candidate{
                .activity_id = c.duckdb_value_int64(&result, 0, idx),
                .kind_id = c.duckdb_value_int64(&result, 1, idx),
                .project_id = c.duckdb_value_int64(&result, 2, idx),
                .app_pattern = "",
                .title_pattern = "",
                .times_used = @intCast(c.duckdb_value_int64(&result, 5, idx)),
                .last_used_days = @intCast(c.duckdb_value_int64(&result, 6, idx)),
                .reason = "Matched rule",
            };

            // Copy app_pattern
            const app_ptr = c.duckdb_value_varchar(&result, 3, idx);
            if (app_ptr != null) {
                const app_len = @min(std.mem.len(app_ptr), 255);
                @memcpy(candidates[i].app_pattern_buf[0..app_len], app_ptr[0..app_len]);
                candidates[i].app_pattern = candidates[i].app_pattern_buf[0..app_len];
                c.duckdb_free(app_ptr);
            }

            // Copy title_pattern
            const title_ptr = c.duckdb_value_varchar(&result, 4, idx);
            if (title_ptr != null) {
                const title_len = @min(std.mem.len(title_ptr), 255);
                @memcpy(candidates[i].title_pattern_buf[0..title_len], title_ptr[0..title_len]);
                candidates[i].title_pattern = candidates[i].title_pattern_buf[0..title_len];
                c.duckdb_free(title_ptr);
            }
        }

        return candidates;
    }

    fn getDisplayPath(self: *SuggestionEngine, activity_id: i64, kind_id: i64) SuggestionError![]const u8 {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql =
            \\SELECT c.name || ' > ' || p.name || ' > ' || ph.name || ' > ' || a.name || ' > ' || k.name
            \\FROM kinds k
            \\JOIN activities a ON k.activity_id = a.activity_id
            \\JOIN phases ph ON a.phase_id = ph.phase_id
            \\JOIN projects p ON ph.project_id = p.project_id
            \\JOIN customers c ON p.customer_id = c.customer_id
            \\WHERE a.activity_id = ? AND k.kind_id = ?
        ;

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return SuggestionError.QueryFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, activity_id);
        _ = c.duckdb_bind_int64(stmt, 2, kind_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            return SuggestionError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        if (c.duckdb_row_count(&result) == 0) {
            const empty = self.allocator.alloc(u8, 0) catch return SuggestionError.OutOfMemory;
            return empty;
        }

        const path_ptr = c.duckdb_value_varchar(&result, 0, 0);
        if (path_ptr == null) {
            const empty = self.allocator.alloc(u8, 0) catch return SuggestionError.OutOfMemory;
            return empty;
        }

        const path_len = std.mem.len(path_ptr);
        const path_copy = self.allocator.alloc(u8, path_len) catch {
            c.duckdb_free(path_ptr);
            return SuggestionError.OutOfMemory;
        };
        @memcpy(path_copy, path_ptr[0..path_len]);
        c.duckdb_free(path_ptr);

        return path_copy;
    }

    fn isInActiveProjects(_: *SuggestionEngine, project_id: i64, active_projects: []const i64) bool {
        for (active_projects) |active_id| {
            if (active_id == project_id) {
                return true;
            }
        }
        return false;
    }
};
