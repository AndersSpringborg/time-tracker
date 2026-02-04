const std = @import("std");
const domain_rule = @import("domain_rule");
const Rule = domain_rule.Rule;
const RuleInput = domain_rule.RuleInput;
const Match = domain_rule.Match;
const findFirstMatch = domain_rule.findFirstMatch;
const rule_repository = @import("rule_repository");
const RuleRepository = rule_repository.RuleRepository;
const RuleRepositoryError = rule_repository.RuleRepositoryError;

/// In-memory fake implementation of RuleRepository for testing.
pub const FakeRuleRepository = struct {
    rules: std.ArrayListUnmanaged(Rule),
    allocator: std.mem.Allocator,
    next_id: i64,

    pub fn init(allocator: std.mem.Allocator) FakeRuleRepository {
        return .{
            .rules = .{},
            .allocator = allocator,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *FakeRuleRepository) void {
        self.rules.deinit(self.allocator);
    }

    pub fn addRule(self: *FakeRuleRepository, input: RuleInput) RuleRepositoryError!void {
        self.rules.append(self.allocator, Rule{
            .id = self.next_id,
            .app_pattern = input.app_pattern,
            .title_pattern = input.title_pattern,
            .activity_id = input.activity_id,
            .kind_id = input.kind_id,
            .priority = input.priority,
            .is_global = input.is_global,
            .kind_name = input.kind_name,
        }) catch return RuleRepositoryError.OutOfMemory;
        self.next_id += 1;
    }

    pub fn findMatch(self: *FakeRuleRepository, app_name: []const u8, window_title: []const u8) RuleRepositoryError!?Match {
        return findFirstMatch(self.rules.items, app_name, window_title);
    }

    pub fn getRuleCount(self: *FakeRuleRepository) RuleRepositoryError!i64 {
        return @intCast(self.rules.items.len);
    }

    /// Convert to the interface type.
    pub fn repository(self: *FakeRuleRepository) RuleRepository {
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
        const self: *FakeRuleRepository = @ptrCast(@alignCast(ptr));
        return self.findMatch(app_name, window_title);
    }

    fn addRuleVtable(ptr: *anyopaque, input: RuleInput) RuleRepositoryError!void {
        const self: *FakeRuleRepository = @ptrCast(@alignCast(ptr));
        return self.addRule(input);
    }

    fn getRuleCountVtable(ptr: *anyopaque) RuleRepositoryError!i64 {
        const self: *FakeRuleRepository = @ptrCast(@alignCast(ptr));
        return self.getRuleCount();
    }
};

test "FakeRuleRepository finds matching rule" {
    var repo = FakeRuleRepository.init(std.testing.allocator);
    defer repo.deinit();

    try repo.addRule(.{
        .app_pattern = "Safari",
        .title_pattern = null,
        .activity_id = 1,
        .kind_id = 10,
    });

    const match = try repo.findMatch("Safari", "Google");
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(i64, 1), match.?.activity_id);
    try std.testing.expectEqual(@as(i64, 10), match.?.kind_id);
}

test "FakeRuleRepository returns null when no match" {
    var repo = FakeRuleRepository.init(std.testing.allocator);
    defer repo.deinit();

    try repo.addRule(.{
        .app_pattern = "Safari",
        .title_pattern = null,
        .activity_id = 1,
        .kind_id = 10,
    });

    const match = try repo.findMatch("Code", "main.zig");
    try std.testing.expect(match == null);
}

test "FakeRuleRepository works through interface" {
    var fake = FakeRuleRepository.init(std.testing.allocator);
    defer fake.deinit();

    const repo = fake.repository();

    try repo.addRule(.{
        .app_pattern = "Code",
        .title_pattern = "*.zig",
        .activity_id = 2,
        .kind_id = 20,
    });

    try std.testing.expectEqual(@as(i64, 1), try repo.getRuleCount());
}
