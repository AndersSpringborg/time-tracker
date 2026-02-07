const std = @import("std");
const rule = @import("rule.zig");
const Rule = rule.Rule;
const RuleInput = rule.RuleInput;

test "Rule.matches with exact app pattern" {
    const r = Rule{
        .id = 1,
        .app_pattern = "Slack",
        .title_pattern = null,
        .activity_id = 10,
        .kind_id = 100,
        .priority = 0,
        .is_global = false,
        .kind_name = null,
        .follow_previous = false,
    };

    try std.testing.expect(r.matches("Slack", "any title"));
    try std.testing.expect(r.matches("slack", "any title")); // case insensitive
    try std.testing.expect(!r.matches("Discord", "any title"));
}

test "Rule.matches with wildcard app pattern" {
    const r = Rule{
        .id = 1,
        .app_pattern = "*Slack*",
        .title_pattern = null,
        .activity_id = 10,
        .kind_id = 100,
        .priority = 0,
        .is_global = false,
        .kind_name = null,
        .follow_previous = false,
    };

    try std.testing.expect(r.matches("Slack", "any title"));
    try std.testing.expect(r.matches("Slack Helper", "any title"));
    try std.testing.expect(r.matches("My Slack App", "any title"));
    try std.testing.expect(!r.matches("Discord", "any title"));
}

test "Rule.matches with title pattern" {
    const r = Rule{
        .id = 1,
        .app_pattern = "Firefox",
        .title_pattern = "*github*",
        .activity_id = 10,
        .kind_id = 100,
        .priority = 0,
        .is_global = false,
        .kind_name = null,
        .follow_previous = false,
    };

    try std.testing.expect(r.matches("Firefox", "Pull Request - GitHub"));
    try std.testing.expect(r.matches("Firefox", "github.com"));
    try std.testing.expect(!r.matches("Firefox", "Google Search"));
    try std.testing.expect(!r.matches("Chrome", "GitHub")); // wrong app
}

test "Rule.matches with null patterns matches anything" {
    const r = Rule{
        .id = 1,
        .app_pattern = null,
        .title_pattern = null,
        .activity_id = 10,
        .kind_id = 100,
        .priority = 0,
        .is_global = false,
        .kind_name = null,
        .follow_previous = false,
    };

    try std.testing.expect(r.matches("Any App", "Any Title"));
    try std.testing.expect(r.matches("", ""));
}

test "findFirstMatch returns first matching rule" {
    const rules = [_]Rule{
        .{
            .id = 1,
            .app_pattern = "Slack",
            .title_pattern = null,
            .activity_id = 10,
            .kind_id = 100,
            .priority = 10,
            .is_global = false,
            .kind_name = null,
            .follow_previous = false,
        },
        .{
            .id = 2,
            .app_pattern = "*",
            .title_pattern = null,
            .activity_id = 20,
            .kind_id = 200,
            .priority = 0,
            .is_global = false,
            .kind_name = null,
            .follow_previous = false,
        },
    };

    // Should match first rule
    const match = rule.findFirstMatch(&rules, "Slack", "Some channel");
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(i64, 1), match.?.rule_id);
    try std.testing.expectEqual(rule.MatchAction.map_kind, match.?.action);
    try std.testing.expectEqual(@as(?i64, 10), match.?.activity_id);
    try std.testing.expectEqual(@as(?i64, 100), match.?.kind_id);
}

test "findFirstMatch returns null when no match" {
    const rules = [_]Rule{
        .{
            .id = 1,
            .app_pattern = "Slack",
            .title_pattern = null,
            .activity_id = 10,
            .kind_id = 100,
            .priority = 10,
            .is_global = false,
            .kind_name = null,
            .follow_previous = false,
        },
    };

    const match = rule.findFirstMatch(&rules, "Discord", "Some channel");
    try std.testing.expect(match == null);
}

test "findFirstMatch skips global rules" {
    const rules = [_]Rule{
        .{
            .id = 1,
            .app_pattern = "Slack",
            .title_pattern = null,
            .activity_id = 10,
            .kind_id = 100,
            .priority = 10,
            .is_global = true, // Global rule - should be skipped
            .kind_name = "Communication",
            .follow_previous = false,
        },
        .{
            .id = 2,
            .app_pattern = "Slack",
            .title_pattern = null,
            .activity_id = 20,
            .kind_id = 200,
            .priority = 5,
            .is_global = false,
            .kind_name = null,
            .follow_previous = false,
        },
    };

    // Should skip global rule and match second rule
    const match = rule.findFirstMatch(&rules, "Slack", "Some channel");
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(i64, 2), match.?.rule_id);
}

test "RuleInput can be created with defaults" {
    const input = RuleInput{
        .app_pattern = "Firefox",
        .title_pattern = null,
        .activity_id = 1,
        .kind_id = 2,
    };

    try std.testing.expectEqual(@as(i32, 0), input.priority);
    try std.testing.expect(!input.is_global);
    try std.testing.expect(input.kind_name == null);
    try std.testing.expect(!input.follow_previous);
}

test "RuleInput can be created as global" {
    const input = RuleInput{
        .app_pattern = "Firefox",
        .title_pattern = null,
        .activity_id = 0, // Not used for global
        .kind_id = 0, // Not used for global
        .is_global = true,
        .kind_name = "Development",
    };

    try std.testing.expect(input.is_global);
    try std.testing.expect(input.kind_name != null);
    try std.testing.expectEqualStrings("Development", input.kind_name.?);
}

test "findFirstMatch returns follow_previous action" {
    const rules = [_]Rule{
        .{
            .id = 1,
            .app_pattern = "Slack",
            .title_pattern = null,
            .activity_id = 0,
            .kind_id = 0,
            .priority = 10,
            .is_global = false,
            .kind_name = null,
            .follow_previous = true,
        },
    };

    const match = rule.findFirstMatch(&rules, "Slack", "any");
    try std.testing.expect(match != null);
    try std.testing.expectEqual(rule.MatchAction.follow_previous, match.?.action);
    try std.testing.expectEqual(@as(?i64, null), match.?.activity_id);
    try std.testing.expectEqual(@as(?i64, null), match.?.kind_id);
}
