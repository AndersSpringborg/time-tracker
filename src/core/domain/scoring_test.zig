const std = @import("std");
const scoring = @import("scoring");
const SuggestionScorer = scoring.SuggestionScorer;
const ScoredSuggestion = scoring.ScoredSuggestion;

// Test 1: Score calculation for exact match
test "SuggestionScorer scores exact match highest" {
    var scorer = SuggestionScorer.init(.{});

    // Perfect match on app and title should score high
    const score = scorer.calculateScore(.{
        .app_name = "IntelliJ IDEA",
        .window_title = "time-tracker - main.zig",
        .candidate_app_pattern = "IntelliJ IDEA",
        .candidate_title_pattern = "time-tracker - main.zig",
        .times_used = 0,
        .recency_days = 0,
        .is_active_project = false,
    });

    // Base score: exact_match_weight (50) for both app and title = 50
    try std.testing.expect(score >= 50);
}

// Test 2: Partial match scores lower than exact
test "SuggestionScorer scores partial match lower" {
    var scorer = SuggestionScorer.init(.{});

    const exact_score = scorer.calculateScore(.{
        .app_name = "Firefox",
        .window_title = "GitHub - time-tracker",
        .candidate_app_pattern = "Firefox",
        .candidate_title_pattern = "GitHub - time-tracker",
        .times_used = 0,
        .recency_days = 0,
        .is_active_project = false,
    });

    const partial_score = scorer.calculateScore(.{
        .app_name = "Firefox",
        .window_title = "GitHub - time-tracker",
        .candidate_app_pattern = "Firefox",
        .candidate_title_pattern = "GitHub*",
        .times_used = 0,
        .recency_days = 0,
        .is_active_project = false,
    });

    try std.testing.expect(exact_score > partial_score);
}

// Test 3: Active project boosts score
test "SuggestionScorer boosts active project score" {
    var scorer = SuggestionScorer.init(.{});

    const without_active = scorer.calculateScore(.{
        .app_name = "IntelliJ IDEA",
        .window_title = "project-x",
        .candidate_app_pattern = "IntelliJ*",
        .candidate_title_pattern = "project-x",
        .times_used = 5,
        .recency_days = 1,
        .is_active_project = false,
    });

    const with_active = scorer.calculateScore(.{
        .app_name = "IntelliJ IDEA",
        .window_title = "project-x",
        .candidate_app_pattern = "IntelliJ*",
        .candidate_title_pattern = "project-x",
        .times_used = 5,
        .recency_days = 1,
        .is_active_project = true,
    });

    try std.testing.expect(with_active > without_active);
}

// Test 4: Recent usage boosts score
test "SuggestionScorer boosts recent usage" {
    var scorer = SuggestionScorer.init(.{});

    const old_usage = scorer.calculateScore(.{
        .app_name = "Firefox",
        .window_title = "JIRA",
        .candidate_app_pattern = "Firefox",
        .candidate_title_pattern = "JIRA",
        .times_used = 10,
        .recency_days = 30, // Used 30 days ago
        .is_active_project = false,
    });

    const recent_usage = scorer.calculateScore(.{
        .app_name = "Firefox",
        .window_title = "JIRA",
        .candidate_app_pattern = "Firefox",
        .candidate_title_pattern = "JIRA",
        .times_used = 10,
        .recency_days = 1, // Used yesterday
        .is_active_project = false,
    });

    try std.testing.expect(recent_usage > old_usage);
}

// Test 5: Frequency boosts score
test "SuggestionScorer boosts frequent usage" {
    var scorer = SuggestionScorer.init(.{});

    const low_freq = scorer.calculateScore(.{
        .app_name = "Firefox",
        .window_title = "JIRA",
        .candidate_app_pattern = "Firefox",
        .candidate_title_pattern = "JIRA",
        .times_used = 1,
        .recency_days = 1,
        .is_active_project = false,
    });

    const high_freq = scorer.calculateScore(.{
        .app_name = "Firefox",
        .window_title = "JIRA",
        .candidate_app_pattern = "Firefox",
        .candidate_title_pattern = "JIRA",
        .times_used = 100,
        .recency_days = 1,
        .is_active_project = false,
    });

    try std.testing.expect(high_freq > low_freq);
}

// Test 6: Sort suggestions by score
test "SuggestionScorer sorts by score descending" {
    var scorer = SuggestionScorer.init(.{});

    var suggestions = [_]ScoredSuggestion{
        .{ .id = 1, .score = 50 },
        .{ .id = 2, .score = 90 },
        .{ .id = 3, .score = 70 },
    };

    scorer.sortByScore(&suggestions);

    try std.testing.expectEqual(@as(u32, 2), suggestions[0].id);
    try std.testing.expectEqual(@as(u32, 3), suggestions[1].id);
    try std.testing.expectEqual(@as(u32, 1), suggestions[2].id);
}

// Test 7: Top N suggestions
test "SuggestionScorer returns top N" {
    var scorer = SuggestionScorer.init(.{});

    var suggestions = [_]ScoredSuggestion{
        .{ .id = 1, .score = 50 },
        .{ .id = 2, .score = 90 },
        .{ .id = 3, .score = 70 },
        .{ .id = 4, .score = 85 },
        .{ .id = 5, .score = 60 },
    };

    const top3 = scorer.topN(&suggestions, 3);

    try std.testing.expectEqual(@as(usize, 3), top3.len);
    try std.testing.expectEqual(@as(u32, 2), top3[0].id); // 90
    try std.testing.expectEqual(@as(u32, 4), top3[1].id); // 85
    try std.testing.expectEqual(@as(u32, 3), top3[2].id); // 70
}

// Test 8: No match returns 0 score
test "SuggestionScorer returns 0 for no match" {
    var scorer = SuggestionScorer.init(.{});

    const score = scorer.calculateScore(.{
        .app_name = "Firefox",
        .window_title = "GitHub",
        .candidate_app_pattern = "IntelliJ*",
        .candidate_title_pattern = "JIRA*",
        .times_used = 100,
        .recency_days = 0,
        .is_active_project = true,
    });

    try std.testing.expectEqual(@as(u32, 0), score);
}

// Test 9: Custom weights
test "SuggestionScorer uses custom weights" {
    var scorer = SuggestionScorer.init(.{
        .active_project_weight = 50, // Heavy weight on active project
        .recency_weight = 0,
        .frequency_weight = 0,
    });

    const without_active = scorer.calculateScore(.{
        .app_name = "Firefox",
        .window_title = "Test",
        .candidate_app_pattern = "Firefox",
        .candidate_title_pattern = "Test",
        .times_used = 0,
        .recency_days = 0,
        .is_active_project = false,
    });

    const with_active = scorer.calculateScore(.{
        .app_name = "Firefox",
        .window_title = "Test",
        .candidate_app_pattern = "Firefox",
        .candidate_title_pattern = "Test",
        .times_used = 0,
        .recency_days = 0,
        .is_active_project = true,
    });

    // Difference should be 50 (the active project weight)
    try std.testing.expectEqual(@as(u32, 50), with_active - without_active);
}
