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

    const VTable = struct {
        findMatch: *const fn (*anyopaque, []const u8, []const u8) RuleRepositoryError!?Match,
        addRule: *const fn (*anyopaque, RuleInput) RuleRepositoryError!void,
        getRuleCount: *const fn (*anyopaque) RuleRepositoryError!i64,
    };

    /// Find a matching rule for the given app/title.
    pub fn findMatch(self: RuleRepository, app_name: []const u8, window_title: []const u8) RuleRepositoryError!?Match {
        return self.vtable.findMatch(self.ptr, app_name, window_title);
    }

    /// Add a new mapping rule.
    pub fn addRule(self: RuleRepository, rule: RuleInput) RuleRepositoryError!void {
        return self.vtable.addRule(self.ptr, rule);
    }

    /// Get the total number of rules.
    pub fn getRuleCount(self: RuleRepository) RuleRepositoryError!i64 {
        return self.vtable.getRuleCount(self.ptr);
    }
};
