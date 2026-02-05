const std = @import("std");
const glob = @import("glob");

/// Input for creating a new mapping rule.
/// This is the data required to create a rule, before it has an ID.
pub const RuleInput = struct {
    app_pattern: ?[]const u8,
    title_pattern: ?[]const u8,
    activity_id: i64,
    kind_id: i64,
    priority: i32 = 0,
    is_global: bool = false,
    kind_name: ?[]const u8 = null,
};

/// A mapping rule that maps app/title patterns to an activity/kind.
/// This represents a rule stored in the database with an ID.
pub const Rule = struct {
    id: i64,
    app_pattern: ?[]const u8,
    title_pattern: ?[]const u8,
    activity_id: i64,
    kind_id: i64,
    priority: i32,
    is_global: bool,
    kind_name: ?[]const u8,

    /// Check if this rule matches the given app name and window title.
    pub fn matches(self: Rule, app_name: []const u8, window_title: []const u8) bool {
        const app_matches = if (self.app_pattern) |pattern|
            glob.match(pattern, app_name)
        else
            true; // null pattern matches any

        const title_matches = if (self.title_pattern) |pattern|
            glob.match(pattern, window_title)
        else
            true; // null pattern matches any

        return app_matches and title_matches;
    }
};

/// Result of a successful rule match.
/// Contains the IDs needed to map an event to an activity/kind.
pub const Match = struct {
    rule_id: i64,
    activity_id: i64,
    kind_id: i64,
};

/// Find the first matching rule from a list of rules.
/// Rules should be sorted by priority (descending) before calling.
/// Returns null if no rule matches.
pub fn findFirstMatch(rules: []const Rule, app_name: []const u8, window_title: []const u8) ?Match {
    for (rules) |rule| {
        if (rule.matches(app_name, window_title)) {
            // Skip global rules here - they need context resolution
            // which is handled by the repository layer
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
