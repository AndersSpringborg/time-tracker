# Review TUI Implementation Plan

## Overview

Build an interactive TUI for reviewing and mapping time tracking events using **libvaxis**. The goal is to efficiently review one day at a time, with multi-select capabilities to bulk-map or discard events, and smart rule creation from selections.

---

## Problem Statement

Current state:
- **5,446 unmapped events** need to be reviewed
- Current review processes events **one-by-one** - too slow
- No way to bulk-select similar events
- No way to discard non-work events
- No day-based filtering

Goal:
- Review events **by day**
- **Multi-select** similar events (same app, similar titles)
- **Bulk map** to a project/kind
- **Bulk discard** personal/non-work time
- **Auto-create rules** from selection patterns

---

## Technology Choice: libvaxis

[libvaxis](https://github.com/rockorager/libvaxis) - Modern TUI library for Zig

### Why libvaxis?

| Feature | Benefit |
|---------|---------|
| Native Zig | No FFI, integrates cleanly |
| Table widget | Built-in multi-select support via `sel_rows` |
| Modern terminal features | RGB colors, mouse support, Unicode |
| Active development | Well-maintained, good examples |

### API Choice: Low-level (not vxfw)

libvaxis offers two APIs:
- **vxfw** (framework) - Flutter-like widget system, takes over event loop
- **Low-level** - Direct control, integrate with existing code

We'll use **low-level API** because:
1. We need to maintain DuckDB connections
2. Table widget already has multi-select
3. Simpler incremental integration
4. The `table.zig` example matches our use case

### Compatibility

- libvaxis requires: Zig 0.15.1+
- Our project uses: Zig 0.16.0-dev.1204
- Status: ✅ Compatible

---

## UI Design

### Main Review Screen

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Review: 2026-02-04 (Tue) │ 1508 unmapped │ 0 selected │ [<] [>]         │
├──────────────────────────────────────────────────────────────────────────┤
│  App              │ Window Title                           │ Duration   │
├───────────────────┼────────────────────────────────────────┼────────────┤
│ ● Helium          │ DonIsaac/zlint: A linter for Zig...    │    0m 18s  │
│   Helium          │ zig/lib/std/mem/Allocator.zig at ma... │    0m 24s  │
│   Helium          │ Zig Interface Revisited | Software...  │    0m 42s  │
│ ● Ghostty         │ time-tracker                           │    5m 12s  │
│   Ghostty         │ time-tracker                           │    3m 45s  │
│   WebStorm        │ frontend – FileTree.tsx                │    2m 30s  │
│   Rocket.Chat     │ Ensure - Trifork Chat                  │    1m 15s  │
│   loginwindow     │                                        │   45m 00s  │
│   ...             │                                        │            │
├──────────────────────────────────────────────────────────────────────────┤
│ j/k:Move  Space:Select  a:Select App  m:Map  d:Discard  r:Rule  q:Quit  │
└──────────────────────────────────────────────────────────────────────────┘
```

**Legend:**
- `●` = Selected row
- Active row highlighted with different background color
- Header row is sticky

### Hierarchy Picker Modal

Appears when pressing `m` to map selected events:

```
┌─────────────────────────────────────────────────────────────────────┐
│  Map 15 events to:                                                  │
├─────────────────────────────────────────────────────────────────────┤
│  Search: ensure_                                                    │
├─────────────────────────────────────────────────────────────────────┤
│ > Ensure > Platform Dev > Backend > Development > Billable         │
│   Ensure > Platform Dev > Frontend > Development > Billable        │
│   Ensure > Platform Dev > Ops > Development > Billable             │
│   Trifork > Internal > Training > Learning > Billable              │
├─────────────────────────────────────────────────────────────────────┤
│ Enter:Select  /:Search  Esc:Cancel  r:Create Rule After            │
└─────────────────────────────────────────────────────────────────────┘
```

### Rule Creation Dialog

Appears when pressing `r` after mapping (or directly from selection):

```
┌─────────────────────────────────────────────────────────────────────┐
│  Create Rule from 15 Selected Events                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  App pattern:    [Helium____________________________]               │
│                  ✓ All 15 events match                              │
│                                                                     │
│  Title pattern:  [*github.com*______________________]               │
│                  ✓ 12 of 15 events match (80%)                      │
│                                                                     │
│  [ ] Make global rule (resolves kind by name in active project)    │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│ Enter:Create  Tab:Next Field  Esc:Cancel                           │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Keyboard Bindings

### Navigation
| Key | Action |
|-----|--------|
| `j` / `↓` | Move down |
| `k` / `↑` | Move up |
| `g` | Go to first row |
| `G` | Go to last row |
| `Ctrl+d` | Page down |
| `Ctrl+u` | Page up |

### Selection
| Key | Action |
|-----|--------|
| `Space` | Toggle select current row |
| `a` | Select all with same app as current |
| `A` | Select all visible |
| `Esc` | Clear selection |
| `v` | Visual select mode (optional) |

### Actions
| Key | Action |
|-----|--------|
| `m` | Map selected events → opens picker |
| `d` | Discard selected events (mark as non-work) |
| `r` | Create rule from selection |
| `u` | Undo last action (if possible) |

### Day Navigation
| Key | Action |
|-----|--------|
| `[` | Previous day with unmapped events |
| `]` | Next day with unmapped events |
| `t` | Jump to today |

### General
| Key | Action |
|-----|--------|
| `q` | Quit |
| `/` | Filter/search events |
| `?` | Show help |
| `Ctrl+l` | Refresh screen |

---

## Data Model Enhancements

### New Queries in Reviewer

```zig
// Get dates that have unmapped events
pub fn getDatesWithUnmappedEvents(self: *Reviewer) ![]DateSummary {
    // Returns: [{ date: "2026-02-04", count: 1508, duration_ms: 48942000 }, ...]
}

pub const DateSummary = struct {
    date: []const u8,        // "2026-02-04"
    unmapped_count: u32,
    total_duration_ms: i64,
};

// Get unmapped events for a specific date
pub fn getUnmappedEventsForDate(self: *Reviewer, date: []const u8) ![]UnmappedEvent {
    // WHERE strftime(to_timestamp(timestamp_ms/1000), '%Y-%m-%d') = ?
}

// Bulk map multiple events
pub fn mapEventsBulk(
    self: *Reviewer, 
    event_ids: []const i64, 
    activity_id: i64, 
    kind_id: i64
) !usize {
    // Returns count of mapped events
}

// Bulk discard (mark as manually reviewed, no mapping)
pub fn discardEventsBulk(self: *Reviewer, event_ids: []const i64) !usize {
    // SET manually_mapped = true, activity_id = NULL
}
```

### Discard Semantics

We'll use the existing schema for discards:
- `manually_mapped = true` 
- `activity_id = NULL`
- `kind_id = NULL`

This means "human reviewed, intentionally not mapped" (personal time).

No migration needed!

---

## Pattern Detection

When creating rules from selection, analyze events to suggest patterns.

### Algorithm

```zig
pub const PatternSuggestion = struct {
    app_pattern: []const u8,
    app_match_count: u32,
    title_pattern: ?[]const u8,
    title_match_count: u32,
    total_events: u32,
};

pub fn detectPatterns(events: []const UnmappedEvent) PatternSuggestion {
    // 1. App pattern
    //    - If all same app → exact match "Helium"
    //    - If mostly same → use most common + suggest
    //    - If varied → use wildcard "*"
    
    // 2. Title pattern  
    //    - Extract common substrings
    //    - Detect URLs → extract domain "*.github.com*"
    //    - Detect project names → "*time-tracker*"
    //    - Find longest common substring among >50% of events
    
    // 3. Return suggestion with match percentages
}
```

### Pattern Examples

| Events | Suggested App | Suggested Title |
|--------|--------------|-----------------|
| All "Helium" with github URLs | `Helium` | `*github.com*` |
| All "Ghostty" with "time-tracker" | `Ghostty` | `*time-tracker*` |
| Mixed apps, all "ensure" in title | `*` | `*ensure*` |
| All "loginwindow", no title | `loginwindow` | `*` |

---

## File Structure

```
src/core/cli/
├── review.zig                  # Data layer (existing, will enhance)
├── review_tui.zig              # NEW: Main TUI entry point
└── review_tui/
    ├── app.zig                 # Application state machine
    ├── views/
    │   ├── event_table.zig     # Main event list view
    │   ├── hierarchy_picker.zig # Modal: select kind
    │   └── rule_dialog.zig     # Modal: create rule
    ├── components/
    │   ├── status_bar.zig      # Bottom status bar
    │   └── header.zig          # Top header with day info
    └── pattern.zig             # Pattern detection logic

build.zig                       # Add vaxis dependency
build.zig.zon                   # Add vaxis to dependencies
```

---

## Implementation Phases

### Phase 1: libvaxis Integration & Basic Table
**Goal:** Display events in a table with j/k navigation

Tasks:
1. Add libvaxis dependency to build.zig.zon
2. Configure build.zig to include vaxis module
3. Create `review_tui.zig` with basic setup:
   - Initialize vaxis
   - Enter alt screen
   - Create event loop
   - Handle q to quit
4. Fetch events from database
5. Render with Table widget
6. Implement j/k navigation

**Deliverable:** Can navigate event list with keyboard

### Phase 2: Multi-Select
**Goal:** Select multiple events with Space, select by app with `a`

Tasks:
1. Wire up Space to toggle `sel_rows`
2. Implement `a` to select all with same app name
3. Show selection count in header
4. Visual feedback (● marker, different color)

**Deliverable:** Can select multiple events

### Phase 3: Day Filtering
**Goal:** Filter by day, navigate between days

Tasks:
1. Add `--date` CLI argument parsing
2. Implement `getUnmappedEventsForDate()`
3. Implement `getDatesWithUnmappedEvents()`
4. Show current date in header
5. Implement `[` and `]` for day navigation
6. Implement `t` for "go to today"

**Deliverable:** Can review specific days, navigate between them

### Phase 4: Hierarchy Picker Modal
**Goal:** Map selected events to a kind

Tasks:
1. Create modal overlay rendering
2. Implement search input
3. Reuse `searchFullHierarchy()` for results
4. j/k navigation in results
5. Enter to select
6. Implement `mapEventsBulk()`
7. Wire up to selection

**Deliverable:** Can map multiple events at once

### Phase 5: Discard Action
**Goal:** Mark events as discarded (non-work)

Tasks:
1. Implement `discardEventsBulk()`
2. Wire up `d` key
3. Confirmation dialog (optional)
4. Remove from list after discard

**Deliverable:** Can discard personal time events

### Phase 6: Rule Creation
**Goal:** Create rules from selection patterns

Tasks:
1. Implement `detectPatterns()`
2. Create rule dialog modal
3. Text input for app pattern
4. Text input for title pattern  
5. Checkbox for global rule
6. Preview match count
7. Create rule via existing RulesEngine

**Deliverable:** Can auto-create rules from event patterns

### Phase 7: Polish
**Goal:** Production-ready UX

Tasks:
1. Colors and styling
2. Help screen (`?`)
3. Status messages
4. Error handling
5. Empty state (no events for day)
6. Celebration when day complete
7. Performance optimization if needed

**Deliverable:** Polished, user-friendly review experience

---

## Technical Details

### libvaxis Setup

**build.zig.zon:**
```zig
.dependencies = .{
    .vaxis = .{
        .url = "git+https://github.com/rockorager/libvaxis.git",
        .hash = "...",  // Will be populated by zig fetch
    },
},
```

**build.zig:**
```zig
const vaxis = b.dependency("vaxis", .{
    .target = target,
    .optimize = optimize,
});

// Add to review_tui module
review_tui_module.addImport("vaxis", vaxis.module("vaxis"));
```

### Application State Machine

```zig
const AppState = enum {
    browsing,        // Main table view
    selecting,       // Visual select mode (optional)
    picking_kind,    // Hierarchy picker modal open
    creating_rule,   // Rule dialog open
    confirming,      // Confirmation dialog
};

const App = struct {
    state: AppState = .browsing,
    
    // Data
    events: []UnmappedEvent,
    current_date: []const u8,
    available_dates: []DateSummary,
    
    // Table state
    table_ctx: vaxis.widgets.Table.TableContext,
    
    // Modal state
    picker: ?PickerState = null,
    rule_dialog: ?RuleDialogState = null,
    
    // Database
    reviewer: *Reviewer,
};
```

### Event Loop Pattern

```zig
pub fn main() !void {
    // Setup allocator, tty, vaxis
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    
    var tty = try vaxis.Tty.init();
    defer tty.deinit();
    
    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.writer());
    
    // Setup database
    var reviewer = Reviewer.init(conn, alloc);
    
    // Load initial data
    var app = App.init(&reviewer, alloc);
    try app.loadEventsForDate("2026-02-04");
    
    // Event loop
    var loop: vaxis.Loop(Event) = .{ .tty = &tty, .vaxis = &vx };
    try loop.start();
    defer loop.stop();
    
    try vx.enterAltScreen(tty.writer());
    
    while (true) {
        const event = loop.nextEvent();
        
        switch (event) {
            .key_press => |key| {
                if (try app.handleKey(key)) break;
            },
            .winsize => |ws| try vx.resize(alloc, tty.writer(), ws),
        }
        
        try app.render(vx.window(), alloc);
        try vx.render(tty.writer());
    }
}
```

---

## Testing Strategy

### Unit Tests

1. **Pattern detection** (`pattern_test.zig`)
   - Common app extraction
   - Title substring detection
   - URL domain extraction
   - Edge cases (empty, single, all different)

2. **Bulk operations** (`review_test.zig`)
   - `mapEventsBulk` with in-memory DB
   - `discardEventsBulk` with in-memory DB
   - Date filtering queries

### Integration Tests

1. Load real-ish data, verify table renders
2. Simulate key sequences, verify state changes

### Manual Testing

- [ ] Navigate with j/k
- [ ] Select with Space
- [ ] Select app with `a`
- [ ] Map with `m`, search, select
- [ ] Discard with `d`
- [ ] Create rule with `r`
- [ ] Navigate days with `[` / `]`
- [ ] Quit with `q`
- [ ] Resize terminal

---

## Open Questions

1. **Undo support?** 
   - Nice to have but complex
   - Could store last N actions and reverse
   - Defer to Phase 8?

2. **Filter/search within day?**
   - `/` to filter visible events
   - Useful for finding specific apps
   - Include in Phase 7?

3. **Group by app view?**
   - Collapse similar events
   - Show count + duration per app
   - Toggle with `g`?
   - Defer to Phase 8?

4. **Persist review position?**
   - Remember where user left off per day
   - Store in DB or local file?
   - Nice to have for Phase 7?

---

## Success Criteria

1. **Speed**: Can review a day's events in < 5 minutes (vs. hours with old UI)
2. **Efficiency**: 80%+ of events handled via bulk operations
3. **Rule coverage**: After first pass, rules auto-map 50%+ of new events
4. **User satisfaction**: Actually enjoyable to use!

---

## Timeline Estimate

| Phase | Est. Sessions | Cumulative |
|-------|---------------|------------|
| Phase 1: Basic Table | 1 | 1 |
| Phase 2: Multi-Select | 1 | 2 |
| Phase 3: Day Filtering | 1 | 3 |
| Phase 4: Hierarchy Picker | 2 | 5 |
| Phase 5: Discard | 0.5 | 5.5 |
| Phase 6: Rule Creation | 2 | 7.5 |
| Phase 7: Polish | 1 | 8.5 |

**Total: ~8-9 sessions**

---

## Next Steps

1. Confirm plan looks good
2. Start Phase 1: `zig fetch --save` libvaxis
3. Create basic scaffold
4. Iterate!
