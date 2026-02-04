const std = @import("std");
const Rule = @import("../../domain/rule.zig").Rule;
const RuleInput = @import("../../domain/rule.zig").RuleInput;
const Match = @import("../../domain/rule.zig").Match;

/// Error type for rule repository operations.
pub const RuleRepositoryError = error{
    QueryFailed,
    InsertFailed,
    DeleteFailed,
    OutOfMemory,
};

/// Interface for storing and querying mapping rules.
/// Implementations: DuckDbRuleRepository
pub const RuleRepository = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        addRule: *const fn (*anyopaque, RuleInput) RuleRepositoryError!void,
        listRules: *const fn (*anyopaque) RuleRepositoryError![]Rule,
        deleteRule: *const fn (*anyopaque, i64) RuleRepositoryError!void,
        getRuleCount: *const fn (*anyopaque) RuleRepositoryError!i64,
        findMatch: *const fn (*anyopaque, []const u8, []const u8) RuleRepositoryError!?Match,
        findMatchWithContext: *const fn (*anyopaque, []const u8, []const u8, ?i64) RuleRepositoryError!?Match,
        freeRules: *const fn (*anyopaque, []Rule) void,
    };

    /// Add a new mapping rule.
    pub fn addRule(self: RuleRepository, rule: RuleInput) RuleRepositoryError!void {
        return self.vtable.addRule(self.ptr, rule);
    }

    /// List all mapping rules, sorted by priority (descending).
    /// Caller must call freeRules() when done.
    pub fn listRules(self: RuleRepository) RuleRepositoryError![]Rule {
        return self.vtable.listRules(self.ptr);
    }

    /// Delete a rule by ID.
    pub fn deleteRule(self: RuleRepository, rule_id: i64) RuleRepositoryError!void {
        return self.vtable.deleteRule(self.ptr, rule_id);
    }

    /// Get the total number of rules.
    pub fn getRuleCount(self: RuleRepository) RuleRepositoryError!i64 {
        return self.vtable.getRuleCount(self.ptr);
    }

    /// Find a matching rule for the given app/title.
    pub fn findMatch(self: RuleRepository, app_name: []const u8, window_title: []const u8) RuleRepositoryError!?Match {
        return self.vtable.findMatch(self.ptr, app_name, window_title);
    }

    /// Find a matching rule with project context for resolving global rules.
    pub fn findMatchWithContext(self: RuleRepository, app_name: []const u8, window_title: []const u8, project_id: ?i64) RuleRepositoryError!?Match {
        return self.vtable.findMatchWithContext(self.ptr, app_name, window_title, project_id);
    }

    /// Free rules returned by listRules().
    pub fn freeRules(self: RuleRepository, rules: []Rule) void {
        self.vtable.freeRules(self.ptr, rules);
    }

    /// Create a RuleRepository from any type that implements the required methods.
    pub fn init(impl: anytype) RuleRepository {
        const Impl = @TypeOf(impl);
        const impl_ptr = if (@typeInfo(Impl) == .pointer) impl else @as(*@TypeOf(impl.*), @ptrCast(@constCast(&impl)));

        const gen = struct {
            fn addRule(ptr: *anyopaque, rule: RuleInput) RuleRepositoryError!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.addRule(rule);
            }

            fn listRules(ptr: *anyopaque) RuleRepositoryError![]Rule {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.listRules();
            }

            fn deleteRule(ptr: *anyopaque, rule_id: i64) RuleRepositoryError!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.deleteRule(rule_id);
            }

            fn getRuleCount(ptr: *anyopaque) RuleRepositoryError!i64 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.getRuleCount();
            }

            fn findMatch(ptr: *anyopaque, app_name: []const u8, window_title: []const u8) RuleRepositoryError!?Match {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.findMatch(app_name, window_title);
            }

            fn findMatchWithContext(ptr: *anyopaque, app_name: []const u8, window_title: []const u8, project_id: ?i64) RuleRepositoryError!?Match {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.findMatchWithContext(app_name, window_title, project_id);
            }

            fn freeRules(ptr: *anyopaque, rules: []Rule) void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                self.freeRules(rules);
            }
        };

        return .{
            .ptr = impl_ptr,
            .vtable = &.{
                .addRule = gen.addRule,
                .listRules = gen.listRules,
                .deleteRule = gen.deleteRule,
                .getRuleCount = gen.getRuleCount,
                .findMatch = gen.findMatch,
                .findMatchWithContext = gen.findMatchWithContext,
                .freeRules = gen.freeRules,
            },
        };
    }
};
