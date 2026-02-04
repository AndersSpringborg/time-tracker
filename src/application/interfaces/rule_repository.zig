const std = @import("std");
const domain_rule = @import("domain_rule");
const Rule = domain_rule.Rule;
const RuleInput = domain_rule.RuleInput;
const Match = domain_rule.Match;

/// Error type for rule repository operations.
pub const RuleRepositoryError = error{
    QueryFailed,
    InsertFailed,
    DeleteFailed,
    OutOfMemory,
};

/// Interface for storing and querying mapping rules.
/// Implementations: DuckDbRuleRepository, FakeRuleRepository
pub const RuleRepository = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    allocator: std.mem.Allocator,

    const VTable = struct {
        findMatch: *const fn (*anyopaque, []const u8, []const u8) RuleRepositoryError!?Match,
        findMatchWithContext: *const fn (*anyopaque, []const u8, []const u8, ?i64) RuleRepositoryError!?Match,
        addRule: *const fn (*anyopaque, RuleInput) RuleRepositoryError!void,
        getRuleCount: *const fn (*anyopaque) RuleRepositoryError!i64,
        listRules: *const fn (*anyopaque) RuleRepositoryError![]Rule,
        deleteRule: *const fn (*anyopaque, i64) RuleRepositoryError!void,
    };

    /// Find a matching rule for the given app/title.
    pub fn findMatch(self: RuleRepository, app_name: []const u8, window_title: []const u8) RuleRepositoryError!?Match {
        return self.vtable.findMatch(self.ptr, app_name, window_title);
    }

    /// Find a matching rule, resolving global rules against the current project.
    pub fn findMatchWithContext(self: RuleRepository, app_name: []const u8, window_title: []const u8, current_project_id: ?i64) RuleRepositoryError!?Match {
        return self.vtable.findMatchWithContext(self.ptr, app_name, window_title, current_project_id);
    }

    /// Add a new mapping rule.
    pub fn addRule(self: RuleRepository, rule: RuleInput) RuleRepositoryError!void {
        return self.vtable.addRule(self.ptr, rule);
    }

    /// Get the total number of rules.
    pub fn getRuleCount(self: RuleRepository) RuleRepositoryError!i64 {
        return self.vtable.getRuleCount(self.ptr);
    }

    /// List all rules. Caller must free the returned slice and its string fields.
    pub fn listRules(self: RuleRepository) RuleRepositoryError![]Rule {
        return self.vtable.listRules(self.ptr);
    }

    /// Free rules returned by listRules.
    pub fn freeRules(self: RuleRepository, rules_list: []Rule) void {
        for (rules_list) |rule| {
            if (rule.app_pattern) |p| self.allocator.free(p);
            if (rule.title_pattern) |p| self.allocator.free(p);
            if (rule.kind_name) |p| self.allocator.free(p);
        }
        self.allocator.free(rules_list);
    }

    /// Delete a rule by ID.
    pub fn deleteRule(self: RuleRepository, rule_id: i64) RuleRepositoryError!void {
        return self.vtable.deleteRule(self.ptr, rule_id);
    }
};
