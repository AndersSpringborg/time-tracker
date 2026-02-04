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
        return self.findMatchWithContext(app_name, window_title, null);
    }

    /// Find a matching rule, resolving global rules against the current project.
    pub fn findMatchWithContext(self: *DuckDbRuleRepository, app_name: []const u8, window_title: []const u8, current_project_id: ?i64) RuleRepositoryError!?Match {
        const fetched_rules = self.listRules() catch return error.QueryFailed;
        defer self.freeRules(fetched_rules);

        // Rules are sorted by priority (DESC)
        for (fetched_rules) |rule| {
            if (rule.matches(app_name, window_title)) {
                if (rule.is_global) {
                    // Global rule: resolve kind_name in current project
                    if (current_project_id) |project_id| {
                        if (rule.kind_name) |kind_name| {
                            if (self.findKindByNameInProject(kind_name, project_id)) |resolved_kind_id| {
                                if (self.getActivityIdForKind(resolved_kind_id)) |resolved_activity_id| {
                                    return Match{
                                        .rule_id = rule.id,
                                        .activity_id = resolved_activity_id,
                                        .kind_id = resolved_kind_id,
                                    };
                                }
                            }
                        }
                    }
                    // Global rule but no current project or kind not found - skip
                    continue;
                } else {
                    // Regular rule: use stored kind_id
                    return Match{
                        .rule_id = rule.id,
                        .activity_id = rule.activity_id,
                        .kind_id = rule.kind_id,
                    };
                }
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

    /// List all rules sorted by priority. Caller must call freeRules when done.
    pub fn listRules(self: *DuckDbRuleRepository) RuleRepositoryError![]Rule {
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
                .app_pattern = self.copyStringValue(&result, 1, row) catch return error.OutOfMemory,
                .title_pattern = self.copyStringValue(&result, 2, row) catch return error.OutOfMemory,
                .activity_id = c.duckdb_value_int64(&result, 3, row),
                .kind_id = c.duckdb_value_int64(&result, 4, row),
                .priority = @intCast(c.duckdb_value_int32(&result, 5, row)),
                .is_global = c.duckdb_value_boolean(&result, 6, row),
                .kind_name = self.copyStringValue(&result, 7, row) catch return error.OutOfMemory,
            };
        }

        return rules_list;
    }

    /// Free rules returned by listRules.
    pub fn freeRules(self: *DuckDbRuleRepository, rules_list: []Rule) void {
        for (rules_list) |rule| {
            if (rule.app_pattern) |p| self.allocator.free(p);
            if (rule.title_pattern) |p| self.allocator.free(p);
            if (rule.kind_name) |p| self.allocator.free(p);
        }
        self.allocator.free(rules_list);
    }

    pub fn deleteRule(self: *DuckDbRuleRepository, rule_id: i64) RuleRepositoryError!void {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "DELETE FROM mapping_rules WHERE id = ?";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return error.DeleteFailed;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, rule_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return error.DeleteFailed;
        }
        c.duckdb_destroy_result(&result);
    }

    /// Look up a kind by name within a specific project.
    fn findKindByNameInProject(self: *DuckDbRuleRepository, kind_name: []const u8, project_id: i64) ?i64 {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql =
            \\SELECT k.kind_id FROM kinds k
            \\JOIN activities a ON k.activity_id = a.activity_id
            \\JOIN phases ph ON a.phase_id = ph.phase_id
            \\WHERE ph.project_id = ? AND LOWER(k.name) = LOWER(?)
            \\LIMIT 1
        ;

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return null;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, project_id);
        _ = c.duckdb_bind_varchar_length(stmt, 2, kind_name.ptr, kind_name.len);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return null;
        }
        defer c.duckdb_destroy_result(&result);

        if (c.duckdb_row_count(&result) == 0) {
            return null;
        }

        return c.duckdb_value_int64(&result, 0, 0);
    }

    /// Get the activity_id for a given kind_id.
    fn getActivityIdForKind(self: *DuckDbRuleRepository, kind_id: i64) ?i64 {
        var stmt: c.duckdb_prepared_statement = undefined;
        const sql = "SELECT activity_id FROM kinds WHERE kind_id = ?";

        if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
            return null;
        }
        defer c.duckdb_destroy_prepare(&stmt);

        _ = c.duckdb_bind_int64(stmt, 1, kind_id);

        var result: c.duckdb_result = undefined;
        if (c.duckdb_execute_prepared(stmt, &result) == c.DuckDBError) {
            c.duckdb_destroy_result(&result);
            return null;
        }
        defer c.duckdb_destroy_result(&result);

        if (c.duckdb_row_count(&result) == 0) {
            return null;
        }

        return c.duckdb_value_int64(&result, 0, 0);
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
            .allocator = self.allocator,
            .vtable = &.{
                .findMatch = findMatchVtable,
                .findMatchWithContext = findMatchWithContextVtable,
                .addRule = addRuleVtable,
                .getRuleCount = getRuleCountVtable,
                .listRules = listRulesVtable,
                .deleteRule = deleteRuleVtable,
            },
        };
    }

    fn findMatchVtable(ptr: *anyopaque, app_name: []const u8, window_title: []const u8) RuleRepositoryError!?Match {
        const self: *DuckDbRuleRepository = @ptrCast(@alignCast(ptr));
        return self.findMatch(app_name, window_title);
    }

    fn findMatchWithContextVtable(ptr: *anyopaque, app_name: []const u8, window_title: []const u8, current_project_id: ?i64) RuleRepositoryError!?Match {
        const self: *DuckDbRuleRepository = @ptrCast(@alignCast(ptr));
        return self.findMatchWithContext(app_name, window_title, current_project_id);
    }

    fn addRuleVtable(ptr: *anyopaque, rule: RuleInput) RuleRepositoryError!void {
        const self: *DuckDbRuleRepository = @ptrCast(@alignCast(ptr));
        return self.addRule(rule);
    }

    fn getRuleCountVtable(ptr: *anyopaque) RuleRepositoryError!i64 {
        const self: *DuckDbRuleRepository = @ptrCast(@alignCast(ptr));
        return self.getRuleCount();
    }

    fn listRulesVtable(ptr: *anyopaque) RuleRepositoryError![]Rule {
        const self: *DuckDbRuleRepository = @ptrCast(@alignCast(ptr));
        return self.listRules();
    }

    fn deleteRuleVtable(ptr: *anyopaque, rule_id: i64) RuleRepositoryError!void {
        const self: *DuckDbRuleRepository = @ptrCast(@alignCast(ptr));
        return self.deleteRule(rule_id);
    }
};
