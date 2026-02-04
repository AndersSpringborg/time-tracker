const std = @import("std");

/// Simple glob matching with * and ? wildcard support.
/// - '*' matches any sequence of zero or more characters
/// - '?' matches exactly one character
/// Case-insensitive matching.
///
/// This is a pure function with no I/O dependencies.
pub fn match(pattern: []const u8, text: []const u8) bool {
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

/// Check if pattern is an exact match (no wildcards).
/// Case-insensitive comparison.
pub fn isExactMatch(pattern: []const u8, text: []const u8) bool {
    // If pattern contains wildcards, it's not exact
    for (pattern) |ch| {
        if (ch == '*' or ch == '?') {
            return false;
        }
    }
    return std.ascii.eqlIgnoreCase(pattern, text);
}
