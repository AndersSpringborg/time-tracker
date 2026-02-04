const std = @import("std");
const glob = @import("glob.zig");

test "glob.match exact match" {
    try std.testing.expect(glob.match("hello", "hello"));
    try std.testing.expect(glob.match("Hello", "hello")); // case insensitive
    try std.testing.expect(glob.match("hello", "Hello")); // case insensitive
    try std.testing.expect(!glob.match("hello", "world"));
    try std.testing.expect(!glob.match("hello", "hell"));
    try std.testing.expect(!glob.match("hello", "helloo"));
}

test "glob.match star wildcard" {
    // Star matches any sequence
    try std.testing.expect(glob.match("*", "anything"));
    try std.testing.expect(glob.match("*", ""));
    try std.testing.expect(glob.match("hello*", "hello"));
    try std.testing.expect(glob.match("hello*", "hello world"));
    try std.testing.expect(glob.match("*world", "hello world"));
    try std.testing.expect(glob.match("*world", "world"));
    try std.testing.expect(glob.match("hello*world", "hello world"));
    try std.testing.expect(glob.match("hello*world", "helloXYZworld"));
    try std.testing.expect(glob.match("*hello*", "say hello world"));

    // Multiple stars
    try std.testing.expect(glob.match("**", "anything"));
    try std.testing.expect(glob.match("a*b*c", "abc"));
    try std.testing.expect(glob.match("a*b*c", "aXXbYYc"));
}

test "glob.match question mark wildcard" {
    // Question mark matches exactly one character
    try std.testing.expect(glob.match("?", "a"));
    try std.testing.expect(!glob.match("?", ""));
    try std.testing.expect(!glob.match("?", "ab"));
    try std.testing.expect(glob.match("h?llo", "hello"));
    try std.testing.expect(glob.match("h?llo", "hallo"));
    try std.testing.expect(!glob.match("h?llo", "hllo"));
    try std.testing.expect(glob.match("???", "abc"));
    try std.testing.expect(!glob.match("???", "ab"));
}

test "glob.match combined wildcards" {
    try std.testing.expect(glob.match("h?llo*", "hello"));
    try std.testing.expect(glob.match("h?llo*", "hallo world"));
    try std.testing.expect(glob.match("*?*", "a"));
    try std.testing.expect(!glob.match("*?*", ""));
    try std.testing.expect(glob.match("a?c*e", "abcde"));
    try std.testing.expect(glob.match("a?c*e", "abcXXXe"));
}

test "glob.match case insensitivity" {
    try std.testing.expect(glob.match("HELLO", "hello"));
    try std.testing.expect(glob.match("Hello", "HELLO"));
    try std.testing.expect(glob.match("H*O", "hello"));
    try std.testing.expect(glob.match("h*O", "HELLO"));
}

test "glob.match real-world patterns" {
    // App name matching
    try std.testing.expect(glob.match("Slack", "Slack"));
    try std.testing.expect(glob.match("slack", "Slack"));
    try std.testing.expect(glob.match("*Slack*", "Slack"));
    try std.testing.expect(glob.match("*slack*", "Slack Helper"));

    // Window title matching
    try std.testing.expect(glob.match("*github*", "Pull Request #123 - GitHub"));
    try std.testing.expect(glob.match("*facebook*", "Facebook - Google Chrome"));
    try std.testing.expect(glob.match("*.ts*", "main.ts - Visual Studio Code"));
}

test "glob.match empty patterns and text" {
    try std.testing.expect(glob.match("", ""));
    try std.testing.expect(!glob.match("", "text"));
    try std.testing.expect(glob.match("*", ""));
    try std.testing.expect(!glob.match("?", ""));
}

test "glob.isExactMatch" {
    // Exact matches
    try std.testing.expect(glob.isExactMatch("hello", "hello"));
    try std.testing.expect(glob.isExactMatch("Hello", "hello")); // case insensitive
    try std.testing.expect(!glob.isExactMatch("hello", "world"));

    // Not exact if contains wildcards
    try std.testing.expect(!glob.isExactMatch("hello*", "hello"));
    try std.testing.expect(!glob.isExactMatch("h?llo", "hello"));
    try std.testing.expect(!glob.isExactMatch("*", ""));
}
