const std = @import("std");

pub const TerminalError = error{
    NotATty,
    GetAttrFailed,
    SetAttrFailed,
    IoctlFailed,
    ReadFailed,
};

pub const Key = union(enum) {
    char: u8,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    enter,
    escape,
    backspace,
    delete,
    tab,
    ctrl_c,
    ctrl_d,
    ctrl_u,
    home,
    end,
    page_up,
    page_down,
    unknown,
};

pub const Color = enum {
    default,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black, // gray
};

pub const Size = struct {
    rows: u16,
    cols: u16,
};

pub const Terminal = struct {
    original_termios: std.posix.termios,
    is_raw: bool,

    const Self = @This();

    pub fn init() TerminalError!Terminal {
        if (!isTty()) {
            return TerminalError.NotATty;
        }

        const original = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch {
            return TerminalError.GetAttrFailed;
        };

        return Terminal{
            .original_termios = original,
            .is_raw = false,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.is_raw) {
            self.disableRawMode() catch {};
        }
        showCursor();
    }

    pub fn isTty() bool {
        return std.posix.isatty(std.posix.STDIN_FILENO);
    }

    pub fn enableRawMode(self: *Self) TerminalError!void {
        var raw = self.original_termios;

        // Disable canonical mode, echo, and signals
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        // Disable input processing
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;

        // Set read to return after 1 byte, with 100ms timeout
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 1; // 100ms timeout

        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw) catch {
            return TerminalError.SetAttrFailed;
        };

        self.is_raw = true;
    }

    pub fn disableRawMode(self: *Self) TerminalError!void {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original_termios) catch {
            return TerminalError.SetAttrFailed;
        };
        self.is_raw = false;
    }

    pub fn getSize() TerminalError!Size {
        var winsize: std.posix.winsize = .{
            .col = 0,
            .row = 0,
            .xpixel = 0,
            .ypixel = 0,
        };

        const result = std.posix.system.ioctl(
            std.posix.STDOUT_FILENO,
            std.posix.T.IOCGWINSZ,
            @intFromPtr(&winsize),
        );

        if (result != 0) {
            return TerminalError.IoctlFailed;
        }

        return Size{
            .rows = winsize.row,
            .cols = winsize.col,
        };
    }

    pub fn readKey(self: *Self) TerminalError!Key {
        _ = self;
        var buf: [8]u8 = undefined;

        const bytes_read = std.posix.read(std.posix.STDIN_FILENO, &buf) catch {
            return TerminalError.ReadFailed;
        };

        if (bytes_read == 0) {
            return Key.unknown; // Timeout
        }

        return parseKey(&buf, bytes_read);
    }
};

/// Parse a key from raw bytes - exposed for testing
pub fn parseKey(buf: []const u8, len: usize) Key {
    if (len == 0) return Key.unknown;

    const first = buf[0];

    // Single byte keys
    if (len == 1) {
        return switch (first) {
            3 => Key.ctrl_c,
            4 => Key.ctrl_d,
            8 => Key.backspace,
            9 => Key.tab,
            10, 13 => Key.enter,
            21 => Key.ctrl_u,
            27 => Key.escape,
            127 => Key.backspace,
            32...126 => Key{ .char = first },
            else => Key.unknown,
        };
    }

    // Escape sequences
    if (first == 27 and len >= 2) {
        if (buf[1] == '[') {
            if (len == 3) {
                // ESC [ X
                return switch (buf[2]) {
                    'A' => Key.arrow_up,
                    'B' => Key.arrow_down,
                    'C' => Key.arrow_right,
                    'D' => Key.arrow_left,
                    'H' => Key.home,
                    'F' => Key.end,
                    else => Key.unknown,
                };
            } else if (len == 4 and buf[3] == '~') {
                // ESC [ N ~
                return switch (buf[2]) {
                    '3' => Key.delete,
                    '5' => Key.page_up,
                    '6' => Key.page_down,
                    else => Key.unknown,
                };
            }
        }
    }

    return Key.unknown;
}

// ANSI escape code generators

pub fn cursorPosition(row: u16, col: u16, buf: []u8) []const u8 {
    const len = std.fmt.bufPrint(buf, "\x1b[{d};{d}H", .{ row, col }) catch return "";
    return buf[0..len.len];
}

pub fn clearLineCode() []const u8 {
    return "\x1b[2K";
}

pub fn clearToEndOfLineCode() []const u8 {
    return "\x1b[K";
}

pub fn clearScreenCode() []const u8 {
    return "\x1b[2J";
}

pub fn hideCursorCode() []const u8 {
    return "\x1b[?25l";
}

pub fn showCursorCode() []const u8 {
    return "\x1b[?25h";
}

pub fn saveCursorCode() []const u8 {
    return "\x1b[s";
}

pub fn restoreCursorCode() []const u8 {
    return "\x1b[u";
}

pub fn boldCode() []const u8 {
    return "\x1b[1m";
}

pub fn resetCode() []const u8 {
    return "\x1b[0m";
}

pub fn fgColorCode(color: Color) []const u8 {
    return switch (color) {
        .default => "\x1b[39m",
        .red => "\x1b[31m",
        .green => "\x1b[32m",
        .yellow => "\x1b[33m",
        .blue => "\x1b[34m",
        .magenta => "\x1b[35m",
        .cyan => "\x1b[36m",
        .white => "\x1b[37m",
        .bright_black => "\x1b[90m",
    };
}

// Convenience functions that write directly to stdout
const stdout = std.io.getStdOut().writer();

pub fn clearScreen() void {
    stdout.writeAll(clearScreenCode()) catch {};
}

pub fn clearLine() void {
    stdout.writeAll(clearLineCode()) catch {};
}

pub fn clearToEndOfLine() void {
    stdout.writeAll(clearToEndOfLineCode()) catch {};
}

pub fn moveCursor(row: u16, col: u16) void {
    var buf: [32]u8 = undefined;
    stdout.writeAll(cursorPosition(row, col, &buf)) catch {};
}

pub fn moveCursorUp(n: u16) void {
    var buf: [16]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d}A", .{n}) catch return;
    stdout.writeAll(seq) catch {};
}

pub fn moveCursorDown(n: u16) void {
    var buf: [16]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d}B", .{n}) catch return;
    stdout.writeAll(seq) catch {};
}

pub fn hideCursor() void {
    stdout.writeAll(hideCursorCode()) catch {};
}

pub fn showCursor() void {
    stdout.writeAll(showCursorCode()) catch {};
}

pub fn saveCursor() void {
    stdout.writeAll(saveCursorCode()) catch {};
}

pub fn restoreCursor() void {
    stdout.writeAll(restoreCursorCode()) catch {};
}

pub fn setBold() void {
    stdout.writeAll(boldCode()) catch {};
}

pub fn resetStyle() void {
    stdout.writeAll(resetCode()) catch {};
}

pub fn setFg(color: Color) void {
    stdout.writeAll(fgColorCode(color)) catch {};
}

pub fn write(text: []const u8) void {
    stdout.writeAll(text) catch {};
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    stdout.print(fmt, args) catch {};
}
