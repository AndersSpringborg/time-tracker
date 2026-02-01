const std = @import("std");
const testing = std.testing;
const terminal = @import("terminal");

// Test key parsing from raw byte sequences
test "parseKey returns char for regular ASCII" {
    const key = terminal.parseKey(&[_]u8{'a'}, 1);
    try testing.expectEqual(terminal.Key{ .char = 'a' }, key);
}

test "parseKey returns char for uppercase" {
    const key = terminal.parseKey(&[_]u8{'Z'}, 1);
    try testing.expectEqual(terminal.Key{ .char = 'Z' }, key);
}

test "parseKey returns enter for carriage return" {
    const key = terminal.parseKey(&[_]u8{13}, 1);
    try testing.expectEqual(terminal.Key.enter, key);
}

test "parseKey returns enter for newline" {
    const key = terminal.parseKey(&[_]u8{10}, 1);
    try testing.expectEqual(terminal.Key.enter, key);
}

test "parseKey returns escape for ESC without following bytes" {
    const key = terminal.parseKey(&[_]u8{27}, 1);
    try testing.expectEqual(terminal.Key.escape, key);
}

test "parseKey returns backspace for DEL (127)" {
    const key = terminal.parseKey(&[_]u8{127}, 1);
    try testing.expectEqual(terminal.Key.backspace, key);
}

test "parseKey returns backspace for BS (8)" {
    const key = terminal.parseKey(&[_]u8{8}, 1);
    try testing.expectEqual(terminal.Key.backspace, key);
}

test "parseKey returns tab" {
    const key = terminal.parseKey(&[_]u8{9}, 1);
    try testing.expectEqual(terminal.Key.tab, key);
}

test "parseKey returns ctrl_c" {
    const key = terminal.parseKey(&[_]u8{3}, 1);
    try testing.expectEqual(terminal.Key.ctrl_c, key);
}

test "parseKey returns ctrl_d" {
    const key = terminal.parseKey(&[_]u8{4}, 1);
    try testing.expectEqual(terminal.Key.ctrl_d, key);
}

test "parseKey returns ctrl_u" {
    const key = terminal.parseKey(&[_]u8{21}, 1);
    try testing.expectEqual(terminal.Key.ctrl_u, key);
}

// Arrow key escape sequences: ESC [ A/B/C/D
test "parseKey returns arrow_up for ESC [ A" {
    const key = terminal.parseKey(&[_]u8{ 27, '[', 'A' }, 3);
    try testing.expectEqual(terminal.Key.arrow_up, key);
}

test "parseKey returns arrow_down for ESC [ B" {
    const key = terminal.parseKey(&[_]u8{ 27, '[', 'B' }, 3);
    try testing.expectEqual(terminal.Key.arrow_down, key);
}

test "parseKey returns arrow_right for ESC [ C" {
    const key = terminal.parseKey(&[_]u8{ 27, '[', 'C' }, 3);
    try testing.expectEqual(terminal.Key.arrow_right, key);
}

test "parseKey returns arrow_left for ESC [ D" {
    const key = terminal.parseKey(&[_]u8{ 27, '[', 'D' }, 3);
    try testing.expectEqual(terminal.Key.arrow_left, key);
}

// Home/End: ESC [ H / ESC [ F
test "parseKey returns home for ESC [ H" {
    const key = terminal.parseKey(&[_]u8{ 27, '[', 'H' }, 3);
    try testing.expectEqual(terminal.Key.home, key);
}

test "parseKey returns end for ESC [ F" {
    const key = terminal.parseKey(&[_]u8{ 27, '[', 'F' }, 3);
    try testing.expectEqual(terminal.Key.end, key);
}

// Page up/down: ESC [ 5 ~ / ESC [ 6 ~
test "parseKey returns page_up for ESC [ 5 ~" {
    const key = terminal.parseKey(&[_]u8{ 27, '[', '5', '~' }, 4);
    try testing.expectEqual(terminal.Key.page_up, key);
}

test "parseKey returns page_down for ESC [ 6 ~" {
    const key = terminal.parseKey(&[_]u8{ 27, '[', '6', '~' }, 4);
    try testing.expectEqual(terminal.Key.page_down, key);
}

// Delete: ESC [ 3 ~
test "parseKey returns delete for ESC [ 3 ~" {
    const key = terminal.parseKey(&[_]u8{ 27, '[', '3', '~' }, 4);
    try testing.expectEqual(terminal.Key.delete, key);
}

test "parseKey returns unknown for unrecognized escape sequence" {
    const key = terminal.parseKey(&[_]u8{ 27, '[', 'X' }, 3);
    try testing.expectEqual(terminal.Key.unknown, key);
}

// ANSI code generation tests
test "cursorPosition generates correct escape sequence" {
    var buf: [32]u8 = undefined;
    const seq = terminal.cursorPosition(5, 10, &buf);
    try testing.expectEqualStrings("\x1b[5;10H", seq);
}

test "cursorPosition handles row 1 col 1" {
    var buf: [32]u8 = undefined;
    const seq = terminal.cursorPosition(1, 1, &buf);
    try testing.expectEqualStrings("\x1b[1;1H", seq);
}

test "clearLineCode returns correct sequence" {
    try testing.expectEqualStrings("\x1b[2K", terminal.clearLineCode());
}

test "clearScreenCode returns correct sequence" {
    try testing.expectEqualStrings("\x1b[2J", terminal.clearScreenCode());
}

test "hideCursorCode returns correct sequence" {
    try testing.expectEqualStrings("\x1b[?25l", terminal.hideCursorCode());
}

test "showCursorCode returns correct sequence" {
    try testing.expectEqualStrings("\x1b[?25h", terminal.showCursorCode());
}

test "boldCode returns correct sequence" {
    try testing.expectEqualStrings("\x1b[1m", terminal.boldCode());
}

test "resetCode returns correct sequence" {
    try testing.expectEqualStrings("\x1b[0m", terminal.resetCode());
}

test "fgColorCode returns correct sequence for green" {
    try testing.expectEqualStrings("\x1b[32m", terminal.fgColorCode(.green));
}

test "fgColorCode returns correct sequence for cyan" {
    try testing.expectEqualStrings("\x1b[36m", terminal.fgColorCode(.cyan));
}

test "fgColorCode returns correct sequence for bright_black (gray)" {
    try testing.expectEqualStrings("\x1b[90m", terminal.fgColorCode(.bright_black));
}
