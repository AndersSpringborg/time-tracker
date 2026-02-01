const std = @import("std");

/// Input for score calculation
pub const ScoreInput = struct {
    app_name: []const u8,
    window_title: []const u8,
    candidate_app_pattern: []const u8,
    candidate_title_pattern: []const u8,
    times_used: u32, // How many times this mapping was used before
    recency_days: u32, // Days since last use (0 = today)
    is_active_project: bool, // Whether this is in the active project context
};

/// A suggestion with its calculated score
pub const ScoredSuggestion = struct {
    id: u32,
    score: u32,
};

/// Configuration for scoring weights
pub const ScoringConfig = struct {
    // Base score for pattern match (0-50)
    exact_match_weight: u32 = 50,
    partial_match_weight: u32 = 30,

    // Bonus weights (added to base)
    active_project_weight: u32 = 25,
    recency_weight: u32 = 15, // Max bonus for recent usage
    frequency_weight: u32 = 10, // Max bonus for frequent usage

    // Decay settings
    recency_half_life_days: u32 = 7, // Score halves every 7 days
    frequency_cap: u32 = 50, // Cap frequency bonus at 50 uses
};

/// Pure algorithm for scoring suggestions based on multiple factors.
/// No database dependencies - follows clean architecture principles.
pub const SuggestionScorer = struct {
    config: ScoringConfig,

    pub fn init(config: ScoringConfig) SuggestionScorer {
        return .{ .config = config };
    }

    /// Calculate a score for a suggestion candidate.
    /// Returns 0-100 score where higher is better.
    pub fn calculateScore(self: *SuggestionScorer, input: ScoreInput) u32 {
        // First check if patterns match at all
        const app_matches = globMatch(input.candidate_app_pattern, input.app_name);
        const title_matches = globMatch(input.candidate_title_pattern, input.window_title);

        // App pattern MUST match for any score (app is the primary identifier)
        // Title pattern matching is optional bonus
        if (!app_matches) {
            return 0;
        }

        var score: u32 = 0;

        // Base score from pattern matching
        if (isExactMatch(input.candidate_app_pattern, input.app_name)) {
            score += self.config.exact_match_weight / 2;
        } else {
            score += self.config.partial_match_weight / 2;
        }

        if (title_matches) {
            if (isExactMatch(input.candidate_title_pattern, input.window_title)) {
                score += self.config.exact_match_weight / 2;
            } else {
                score += self.config.partial_match_weight / 2;
            }
        }

        // Bonus for active project
        if (input.is_active_project) {
            score += self.config.active_project_weight;
        }

        // Recency bonus (exponential decay)
        if (input.recency_days < 365 and self.config.recency_weight > 0) {
            // Calculate decay: bonus = max_bonus * (0.5 ^ (days / half_life))
            const half_life = self.config.recency_half_life_days;
            const decay_factor = std.math.pow(f32, 0.5, @as(f32, @floatFromInt(input.recency_days)) / @as(f32, @floatFromInt(half_life)));
            const recency_bonus: u32 = @intFromFloat(@as(f32, @floatFromInt(self.config.recency_weight)) * decay_factor);
            score += recency_bonus;
        }

        // Frequency bonus (logarithmic scale, capped)
        if (input.times_used > 0 and self.config.frequency_weight > 0) {
            const capped_uses = @min(input.times_used, self.config.frequency_cap);
            // Logarithmic scaling: bonus = max_bonus * log2(uses + 1) / log2(cap + 1)
            const log_uses = std.math.log2(@as(f32, @floatFromInt(capped_uses + 1)));
            const log_cap = std.math.log2(@as(f32, @floatFromInt(self.config.frequency_cap + 1)));
            const freq_bonus: u32 = @intFromFloat(@as(f32, @floatFromInt(self.config.frequency_weight)) * (log_uses / log_cap));
            score += freq_bonus;
        }

        // Cap at 100
        return @min(score, 100);
    }

    /// Sort suggestions by score in descending order.
    pub fn sortByScore(_: *SuggestionScorer, suggestions: []ScoredSuggestion) void {
        std.mem.sort(ScoredSuggestion, suggestions, {}, struct {
            fn lessThan(_: void, a: ScoredSuggestion, b: ScoredSuggestion) bool {
                return a.score > b.score; // Descending order
            }
        }.lessThan);
    }

    /// Get top N suggestions after sorting.
    pub fn topN(self: *SuggestionScorer, suggestions: []ScoredSuggestion, n: usize) []ScoredSuggestion {
        self.sortByScore(suggestions);
        return suggestions[0..@min(n, suggestions.len)];
    }
};

/// Check if pattern is an exact match (no wildcards)
fn isExactMatch(pattern: []const u8, text: []const u8) bool {
    // If pattern contains wildcards, it's not exact
    for (pattern) |ch| {
        if (ch == '*' or ch == '?') {
            return false;
        }
    }
    return std.ascii.eqlIgnoreCase(pattern, text);
}

/// Simple glob matching with * wildcard support.
/// Case-insensitive matching.
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p_idx: usize = 0;
    var t_idx: usize = 0;
    var star_p_idx: ?usize = null;
    var star_t_idx: usize = 0;

    while (t_idx < text.len) {
        if (p_idx < pattern.len) {
            const p_char = std.ascii.toLower(pattern[p_idx]);
            const t_char = std.ascii.toLower(text[t_idx]);

            if (p_char == '*') {
                // Star matches zero or more characters
                star_p_idx = p_idx;
                star_t_idx = t_idx;
                p_idx += 1;
                continue;
            } else if (p_char == t_char or p_char == '?') {
                // Direct match or single-char wildcard
                p_idx += 1;
                t_idx += 1;
                continue;
            }
        }

        // No match - backtrack if we have a star
        if (star_p_idx) |star_idx| {
            p_idx = star_idx + 1;
            star_t_idx += 1;
            t_idx = star_t_idx;
        } else {
            return false;
        }
    }

    // Skip trailing stars
    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}
