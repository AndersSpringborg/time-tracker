const std = @import("std");

// Import functions from Swift bridge
extern fn check_accessibility() bool;
extern fn start_listening(cb: *const fn ([*c]const u8, [*c]const u8, i32) callconv(.c) void) void;

// Callback that Swift calls on each event
fn onEvent(
    c_app: [*c]const u8,
    c_title: [*c]const u8,
    error_code: i32,
) callconv(.c) void {
    if (error_code == 1) {
        std.debug.print(
            \\
            \\ERROR: Accessibility permission required!
            \\
            \\Please grant access in:
            \\  System Settings → Privacy & Security → Accessibility
            \\
            \\Add your Terminal app (or the binary) and restart.
            \\
        , .{});
        return;
    }

    const app = std.mem.span(c_app);
    const title = std.mem.span(c_title);

    std.debug.print("[Event] App: {s} | Title: {s}\n", .{ app, title });
}

pub fn main() void {
    std.debug.print("=== Swift + Zig Window Tracker Demo ===\n\n", .{});

    if (!check_accessibility()) {
        std.debug.print("Warning: Accessibility not yet granted. Will report error on start.\n\n", .{});
    }

    std.debug.print("Starting event listener... (switch windows to see events)\n", .{});
    std.debug.print("Press Ctrl+C to exit.\n\n", .{});

    // Hand control to Swift's NSRunLoop (blocks forever)
    start_listening(&onEvent);
}
