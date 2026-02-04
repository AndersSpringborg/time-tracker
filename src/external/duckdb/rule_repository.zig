const std = @import("std");
const domain_rule = @import("domain_rule");
const Rule = domain_rule.Rule;
const RuleInput = domain_rule.RuleInput;
const Match = domain_rule.Match;
const rule_repository = @import("rule_repository");
const RuleRepository = rule_repository.RuleRepository;
const RuleRepositoryError = rule_repository.RuleRepositoryError;
const migrations = @import("migrations");
const c = migrations.c;

/// DuckDB implementation of RuleRepository.
pub const DuckDbRuleRepository = struct {
    conn: c.duckdb_connection,
    allocator: std.mem.Allocator,

    pub fn init(conn: c.duckdb_connection, allocator: std.mem.Allocator) DuckDbRuleRepository {
        return .{
            .conn = conn,
            .allocator = allocator,
        };
    }

    pub fn findMatch(self: *DuckDbRuleRepository, app_name: []const u8, window_title: []const u8) RuleRepositoryError!?Match {
        // Fetch all rules sorted by priority
        const fetched_rules = self.listRulesInternal() catch return error.QueryFailed;
        defer {
            for (fetched_rules) |rule| {
                if (rule.app_pattern) |p| self.allocator.free(p);
                if (rule.title_pattern) |p| self.allocator.free(p);
                if (rule.kind_name) |p| self.allocator.free(p);
            }
            self.allocator.free(fetched_rules);
        }

        // Rules are sorted by priority (DESC)
        for (fetched_rules) |rule| {
            if (rule.matches(app_name, window_title)) {
                // Skip global rules - they need context resolution
                if (rule.is_global) {
                    continue;
                }
                return Match{
                    .rule_id = rule.id,
                    .activity_id = rule.activity_id,
                    .kind_id = rule.kind_id,
                };
            }
        }

        return null;
    }

    pub fn addRule(self: *DuckDbRuleRepository, rule: RuleInput) RuleRepositoryError!void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "INSERT INTO mapping_rules (app_pattern, title_pattern, activity_id, kind_id, priority, is_global, kind_name) VALUES (?, ?, ?, ?, ?, ?, ?)";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return error.InsertFailed;
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
        _ = c.duckdb_bind_boolean(stmt, 6, rule.is_global);

        if (rule.kind_name) |name| {
            _ = c.duckdb_bind_varchar_length(stmt, 7, name.ptr, name.len);
        } else {
            _ = c.duckdb_bind_null(stmt, 7);
        }

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return error.InsertFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    pub fn getRuleCount(self: *DuckDbRuleRepository) RuleRepositoryError!i64 {
        var result: c.duckdb_result = undefined;
        const query = "SELECT COUNT(*) FROM mapping_rules";

        if (c.duckdb_query(self.conn, query, &result) == c.DuckDBError) {
            return error.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        return c.duckdb_value_int64(&result, 0, 0);
    }

    /// Internal: fetch all rules sorted by priority.
    fn listRulesInternal(self: *DuckDbRuleRepository) ![]Rule {
        var result: c.duckdb_result = undefined;
        const query = "SELECT id, app_pattern, title_pattern, activity_id, kind_id, priority, is_global, kind_name FROM mapping_rules ORDER BY priority DESC";

        if (c.duckdb_query(self.conn, query, &result) == c.DuckDBError) {
            return error.QueryFailed;
        }
        defer c.duckdb_destroy_result(&result);

        const row_count = c.duckdb_row_count(&result);
        var rules_list = self.allocator.alloc(Rule, row_count) catch {
            return error.OutOfMemory;
        };
        errdefer self.allocator.free(rules_list);

        for (0..row_count) |i| {
            const row: c.idx_t = @intCast(i);

            rules_list[i] = Rule{
                .id = c.duckdb_value_int64(&result, 0, row),
                .app_pattern = try self.copyStringValue(&result, 1, row),
                .title_pattern = try self.copyStringValue(&result, 2, row),
                .activity_id = c.duckdb_value_int64(&result, 3, row),
                .kind_id = c.duckdb_value_int64(&result, 4, row),
                .priority = @intCast(c.duckdb_value_int32(&result, 5, row)),
                .is_global = c.duckdb_value_boolean(&result, 6, row),
                .kind_name = try self.copyStringValue(&result, 7, row),
            };
        }

        return rules_list;
    }

    /// Copy a nullable string from DuckDB result to owned memory.
    fn copyStringValue(self: *DuckDbRuleRepository, result: *c.duckdb_result, col: c.idx_t, row: c.idx_t) !?[]const u8 {
        if (c.duckdb_value_is_null(result, col, row)) {
            return null;
        }
        const str = c.duckdb_value_varchar(result, col, row);
        if (str == null) return null;
        defer c.duckdb_free(str);

        const len = std.mem.len(str);
        const copy = self.allocator.alloc(u8, len) catch return error.OutOfMemory;
        @memcpy(copy, str[0..len]);
        return copy;
    }

    /// Convert to the interface type.
    pub fn repository(self: *DuckDbRuleRepository) RuleRepository {
        return RuleRepository{
            .ptr = self,
            .vtable = &.{
                .findMatch = findMatchVtable,
                .addRule = addRuleVtable,
                .getRuleCount = getRuleCountVtable,
            },
        };
    }

    fn findMatchVtable(ptr: *anyopaque, app_name: []const u8, window_title: []const u8) RuleRepositoryError!?Match {
        const self: *DuckDbRuleRepository = @ptrCast(@alignCast(ptr));
        return self.findMatch(app_name, window_title);
    }

    fn addRuleVtable(ptr: *anyopaque, rule: RuleInput) RuleRepositoryError!void {
        const self: *DuckDbRuleRepository = @ptrCast(@alignCast(ptr));
        return self.addRule(rule);
    }

    fn getRuleCountVtable(ptr: *anyopaque) RuleRepositoryError!i64 {
        const self: *DuckDbRuleRepository = @ptrCast(@alignCast(ptr));
        return self.getRuleCount();
    }
};
