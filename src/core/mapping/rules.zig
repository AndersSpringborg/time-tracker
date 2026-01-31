const std = @import("std");
const migrations = @import("migrations");
const c = migrations.c;

pub const RuleError = error{
    QueryFailed,
    InsertFailed,
    DeleteFailed,
    OutOfMemory,
};

pub const RuleInput = struct {
    app_pattern: ?[]const u8,
    title_pattern: ?[]const u8,
    activity_id: i64,
    kind_id: i64,
    priority: i32 = 0,
};

pub const Rule = struct {
    id: i64,
    app_pattern: ?[]const u8,
    title_pattern: ?[]const u8,
    activity_id: i64,
    kind_id: i64,
    priority: i32,
};

pub const Match = struct {
    rule_id: i64,
    activity_id: i64,
    kind_id: i64,
};

pub const RulesEngine = struct {
    conn: c.duckdb_connection,
    allocator: std.mem.Allocator,

    pub fn init(conn: c.duckdb_connection, allocator: std.mem.Allocator) RulesEngine {
        return RulesEngine{
            .conn = conn,
            .allocator = allocator,
        };
    }

    pub fn addRule(self: *RulesEngine, rule: RuleInput) !void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "INSERT INTO mapping_rules (app_pattern, title_pattern, activity_id, kind_id, priority) VALUES (?, ?, ?, ?, ?)";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return RuleError.InsertFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        if (rule.app_pattern) |pattern| {
            _ = c.duckdb_bind_varchar_length(stmt, 1, pattern.ptr, pattern.len);
        } else {
            _ = c.duckdb_bind_null(stmt, 1);
        }

        if (rule.title_pattern) |pattern| {
            _ = c.duckdb_bind_varchar_length(stmt, 2, pattern.ptr, pattern.len);
        } else {
            _ = c.duckdb_bind_null(stmt, 2);
        }

        _ = c.duckdb_bind_int64(stmt, 3, rule.activity_id);
        _ = c.duckdb_bind_int64(stmt, 4, rule.kind_id);
        _ = c.duckdb_bind_int32(stmt, 5, rule.priority);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return RuleError.InsertFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    pub fn getRuleCount(self: *RulesEngine) !i64 {
        var result: c.duckdb_result = undefined;
        const query = "SELECT COUNT(*) FROM mapping_rules";

        if (c.duckdb_query(self.conn, query, &result) == c.DuckDBError) {
            return RuleError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        return c.duckdb_value_int64(&result, 0, 0);
    }

    pub fn listRules(self: *RulesEngine) ![]Rule {
        var result: c.duckdb_result = undefined;
        const query = "SELECT id, app_pattern, title_pattern, activity_id, kind_id, priority FROM mapping_rules ORDER BY priority DESC";

        if (c.duckdb_query(self.conn, query, &result) == c.DuckDBError) {
            return RuleError.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var rules_list = self.allocator.alloc(Rule, row_count) catch {
            return RuleError.OutOfMemory;
        };

        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);

            rules_list[i] = Rule{
                .id = c.duckdb_value_int64(&result, 0, row),
                .app_pattern = getStringValue(&result, 1, row),
                .title_pattern = getStringValue(&result, 2, row),
                .activity_id = c.duckdb_value_int64(&result, 3, row),
                .kind_id = c.duckdb_value_int64(&result, 4, row),
                .priority = @intCast(c.duckdb_value_int32(&result, 5, row)),
            };
        }

        return rules_list;
    }

    pub fn deleteRule(self: *RulesEngine, rule_id: i64) !void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "DELETE FROM mapping_rules WHERE id = ?";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return RuleError.DeleteFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, rule_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return RuleError.DeleteFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    pub fn findMatch(self: *RulesEngine, app_name: []const u8, window_title: []const u8) !?Match {
        const fetched_rules = try self.listRules();
        defer self.allocator.free(fetched_rules);

        // Rules are already sorted by priority (DESC)
        for (fetched_rules) |rule| {
            const app_matches = if (rule.app_pattern) |pattern|
                globMatch(pattern, app_name)
            else
                true; // null pattern matches any

            const title_matches = if (rule.title_pattern) |pattern|
                globMatch(pattern, window_title)
            else
                true; // null pattern matches any

            if (app_matches and title_matches) {
                return Match{
                    .rule_id = rule.id,
                    .activity_id = rule.activity_id,
                    .kind_id = rule.kind_id,
                };
            }
        }

        return null;
    }
};

fn getStringValue(result: *c.duckdb_result, col: c.idx_t, row: c.idx_t) ?[]const u8 {
    if (c.duckdb_value_is_null(result, col, row)) {
        return null;
    }
    const str = c.duckdb_value_varchar(result, col, row);
    if (str == null) return null;
    return std.mem.sliceTo(str, 0);
}

/// Simple glob matching supporting:
/// - '*' matches any sequence of characters
/// - Case insensitive matching
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    // Convert to lowercase for comparison
    var pattern_lower: [256]u8 = undefined;
    var text_lower: [512]u8 = undefined;

    const pattern_len = @min(pattern.len, 256);
    const text_len = @min(text.len, 512);

    for (0..pattern_len) |i| {
        pattern_lower[i] = std.ascii.toLower(pattern[i]);
    }

    for (0..text_len) |i| {
        text_lower[i] = std.ascii.toLower(text[i]);
    }

    const p = pattern_lower[0..pattern_len];
    const t = text_lower[0..text_len];

    return globMatchInternal(p, t);
}

fn globMatchInternal(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (ti < text.len) {
        if (pi < pattern.len and pattern[pi] == '*') {
            star_idx = pi;
            match_idx = ti;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == text[ti]) {
            pi += 1;
            ti += 1;
        } else if (star_idx) |star| {
            pi = star + 1;
            match_idx += 1;
            ti = match_idx;
        } else {
            return false;
        }
    }

    // Check remaining pattern for stars
    while (pi < pattern.len and pattern[pi] == '*') {
        pi += 1;
    }

    return pi == pattern.len;
}
