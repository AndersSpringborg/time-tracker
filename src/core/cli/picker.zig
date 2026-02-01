const std = @import("std");
const terminal = @import("terminal");
const Terminal = terminal.Terminal;
const Key = terminal.Key;
const Color = terminal.Color;

pub const PickerError = error{
    NotATty,
    TerminalFailed,
    Cancelled,
};

/// An item that can be displayed in the picker
pub const PickerItem = struct {
    id: i64,
    display_text: []const u8,
    secondary_text: []const u8, // e.g., "Active project" or score info
    is_highlighted: bool, // e.g., active project marker
};

/// Result of a picker selection
pub const PickerResult = struct {
    selected_id: i64,
    selected_index: usize,
};

/// Interactive picker with vim-style navigation and live filtering
pub const Picker = struct {
    term: Terminal,
    allocator: std.mem.Allocator,

    // State
    items: []const PickerItem,
    filtered_indices: []usize,
    filter_text: std.ArrayListUnmanaged(u8),
    selected_index: usize,
    scroll_offset: usize,
    visible_rows: usize,

    // UI configuration
    title: []const u8,
    help_text: []const u8,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        items: []const PickerItem,
        title: []const u8,
    ) PickerError!Picker {
        var term = Terminal.init() catch return PickerError.NotATty;
        term.enableRawMode() catch return PickerError.TerminalFailed;

        const size = Terminal.getSize() catch terminal.Size{ .rows = 24, .cols = 80 };
        const visible = @max(3, size.rows - 6); // Reserve space for header/footer

        const filter_text: std.ArrayListUnmanaged(u8) = .{};

        // Initially all items are visible
        var filtered = allocator.alloc(usize, items.len) catch {
            term.deinit();
            return PickerError.TerminalFailed;
        };
        for (items, 0..) |_, i| {
            filtered[i] = i;
        }

        return Picker{
            .term = term,
            .allocator = allocator,
            .items = items,
            .filtered_indices = filtered,
            .filter_text = filter_text,
            .selected_index = 0,
            .scroll_offset = 0,
            .visible_rows = visible,
            .title = title,
            .help_text = "j/↓: down  k/↑: up  Enter: select  Esc: cancel  Type to filter",
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.filtered_indices);
        self.filter_text.deinit(self.allocator);
        terminal.showCursor();
        terminal.resetStyle();
        terminal.clearScreen();
        terminal.moveCursor(1, 1);
        self.term.deinit();
    }

    /// Run the picker and return the selected item
    pub fn run(self: *Self) PickerError!PickerResult {
        terminal.hideCursor();
        self.render();

        while (true) {
            const key = self.term.readKey() catch return PickerError.TerminalFailed;

            switch (key) {
                .escape, .ctrl_c => return PickerError.Cancelled,
                .enter => {
                    if (self.filtered_indices.len > 0) {
                        const actual_index = self.filtered_indices[self.selected_index];
                        return PickerResult{
                            .selected_id = self.items[actual_index].id,
                            .selected_index = actual_index,
                        };
                    }
                },
                .arrow_up => self.moveUp(),
                .arrow_down => self.moveDown(),
                .char => |c| {
                    switch (c) {
                        'k' => self.moveUp(),
                        'j' => self.moveDown(),
                        'g' => self.goToTop(),
                        'G' => self.goToBottom(),
                        'q' => return PickerError.Cancelled,
                        else => {
                            self.filter_text.append(self.allocator, c) catch {};
                            self.updateFilter();
                        },
                    }
                },
                .backspace => {
                    if (self.filter_text.items.len > 0) {
                        _ = self.filter_text.pop();
                        self.updateFilter();
                    }
                },
                .ctrl_u => {
                    self.filter_text.clearRetainingCapacity();
                    self.updateFilter();
                },
                .page_up => self.pageUp(),
                .page_down => self.pageDown(),
                .home => self.goToTop(),
                .end => self.goToBottom(),
                else => {},
            }

            self.render();
        }
    }

    fn moveUp(self: *Self) void {
        if (self.selected_index > 0) {
            self.selected_index -= 1;
            if (self.selected_index < self.scroll_offset) {
                self.scroll_offset = self.selected_index;
            }
        }
    }

    fn moveDown(self: *Self) void {
        if (self.filtered_indices.len > 0 and self.selected_index < self.filtered_indices.len - 1) {
            self.selected_index += 1;
            if (self.selected_index >= self.scroll_offset + self.visible_rows) {
                self.scroll_offset = self.selected_index - self.visible_rows + 1;
            }
        }
    }

    fn goToTop(self: *Self) void {
        self.selected_index = 0;
        self.scroll_offset = 0;
    }

    fn goToBottom(self: *Self) void {
        if (self.filtered_indices.len > 0) {
            self.selected_index = self.filtered_indices.len - 1;
            if (self.selected_index >= self.visible_rows) {
                self.scroll_offset = self.selected_index - self.visible_rows + 1;
            }
        }
    }

    fn pageUp(self: *Self) void {
        if (self.selected_index > self.visible_rows) {
            self.selected_index -= self.visible_rows;
        } else {
            self.selected_index = 0;
        }
        if (self.scroll_offset > self.visible_rows) {
            self.scroll_offset -= self.visible_rows;
        } else {
            self.scroll_offset = 0;
        }
    }

    fn pageDown(self: *Self) void {
        self.selected_index = @min(
            self.selected_index + self.visible_rows,
            if (self.filtered_indices.len > 0) self.filtered_indices.len - 1 else 0,
        );
        self.scroll_offset = @min(
            self.scroll_offset + self.visible_rows,
            if (self.filtered_indices.len > self.visible_rows)
                self.filtered_indices.len - self.visible_rows
            else
                0,
        );
    }

    fn updateFilter(self: *Self) void {
        // Reset filter list
        var count: usize = 0;
        const filter = self.filter_text.items;

        for (self.items, 0..) |item, i| {
            if (filter.len == 0 or self.matchesFilter(item.display_text, filter)) {
                self.filtered_indices[count] = i;
                count += 1;
            }
        }

        // Shrink to actual count (we reuse the same allocation)
        self.filtered_indices = self.filtered_indices[0..count];

        // Reset selection if needed
        if (count == 0) {
            self.selected_index = 0;
            self.scroll_offset = 0;
        } else if (self.selected_index >= count) {
            self.selected_index = count - 1;
            if (self.selected_index >= self.visible_rows) {
                self.scroll_offset = self.selected_index - self.visible_rows + 1;
            } else {
                self.scroll_offset = 0;
            }
        }
    }

    fn matchesFilter(_: *Self, text: []const u8, filter: []const u8) bool {
        // Simple case-insensitive substring match
        if (filter.len == 0) return true;
        if (text.len < filter.len) return false;

        for (0..(text.len - filter.len + 1)) |i| {
            var matches = true;
            for (filter, 0..) |fc, j| {
                const tc = text[i + j];
                if (std.ascii.toLower(tc) != std.ascii.toLower(fc)) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }

    fn render(self: *Self) void {
        terminal.clearScreen();
        terminal.moveCursor(1, 1);

        // Title bar
        terminal.setBold();
        terminal.setFg(Color.cyan);
        terminal.print("─── {s} ───\n", .{self.title});
        terminal.resetStyle();

        // Filter input
        terminal.setFg(Color.yellow);
        terminal.write("Filter: ");
        terminal.resetStyle();
        if (self.filter_text.items.len > 0) {
            terminal.write(self.filter_text.items);
        }
        terminal.setFg(Color.bright_black);
        terminal.print(" ({d} matches)\n", .{self.filtered_indices.len});
        terminal.resetStyle();
        terminal.write("\n");

        // Items
        const end_idx = @min(self.scroll_offset + self.visible_rows, self.filtered_indices.len);

        if (self.filtered_indices.len == 0) {
            terminal.setFg(Color.bright_black);
            terminal.write("  (no matches)\n");
            terminal.resetStyle();
        } else {
            for (self.scroll_offset..end_idx) |display_idx| {
                const actual_idx = self.filtered_indices[display_idx];
                const item = self.items[actual_idx];
                const is_selected = display_idx == self.selected_index;

                if (is_selected) {
                    terminal.setFg(Color.green);
                    terminal.write("> ");
                } else {
                    terminal.write("  ");
                }

                if (item.is_highlighted) {
                    terminal.setFg(Color.yellow);
                    terminal.write("★ ");
                }

                if (is_selected) {
                    terminal.setBold();
                }
                terminal.write(item.display_text);
                terminal.resetStyle();

                if (item.secondary_text.len > 0) {
                    terminal.setFg(Color.bright_black);
                    terminal.print(" ({s})", .{item.secondary_text});
                    terminal.resetStyle();
                }

                terminal.write("\n");
            }
        }

        // Scroll indicator
        if (self.filtered_indices.len > self.visible_rows) {
            terminal.write("\n");
            terminal.setFg(Color.bright_black);
            terminal.print("  [{d}-{d} of {d}]", .{
                self.scroll_offset + 1,
                end_idx,
                self.filtered_indices.len,
            });
            terminal.resetStyle();
        }

        // Help text
        terminal.write("\n\n");
        terminal.setFg(Color.bright_black);
        terminal.write(self.help_text);
        terminal.resetStyle();
    }
};
