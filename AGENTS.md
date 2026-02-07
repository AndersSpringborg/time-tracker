# AGENTS.md - Time Tracker

Low-power, event-driven time tracker daemon for macOS with hybrid Swift/Zig architecture.

## Architecture

- **Swift** (`src/bridge/`): macOS sensor - Accessibility API for window/app tracking
- **Zig** (`src/core/`): Main logic, CLI, database operations
- **DuckDB**: Embedded SQL database (embedded assets in `third_party/duckdb/`)

## Build Commands

```bash
zig build              # Build the application
zig build test         # Run all tests
zig build run -- <args> # Run with arguments
./zig-out/bin/time_tracker <command>  # Run binary directly
```

## Project Structure

```
src/
├── bridge/macos_bridge.swift  # Swift ↔ Zig FFI, macOS APIs
├── core/
│   ├── main.zig               # CLI entry point
│   ├── domain/                # Core types (Event, scoring)
│   ├── storage/               # DuckDB repository, migrations
│   ├── mapping/               # Rule engine for app → activity
│   ├── cli/                   # Terminal UI, picker
│   └── ...
```

Test files are co-located: `event.zig` → `event_test.zig`

## Zig Code Style

**Imports** - `std` first, then modules:
```zig
const std = @import("std");
const migrations = @import("migrations");
const c = migrations.c;
```

**Naming**:
- Types: `PascalCase` (`RulesEngine`, `ImportStats`)
- Functions/variables: `camelCase` (`findMatch`, `rule_count`)
- Error sets: `PascalCase` + `Error` suffix (`RuleError`)

**Error Handling** - Explicit error sets, not `anyerror`:
```zig
pub const RuleError = error{ QueryFailed, InsertFailed, OutOfMemory };

pub fn addRule(self: *RulesEngine, rule: RuleInput) !void {
    // returns RuleError on failure
}
```

**Memory** - Use `defer` for cleanup, pass allocator explicitly:
```zig
const items = allocator.alloc(Item, count) catch return error.OutOfMemory;
defer allocator.free(items);
```

**DuckDB** - Prepared statements, check return codes:
```zig
var stmt: c.duckdb_prepared_statement = undefined;
if (c.duckdb_prepare(self.conn, sql, &stmt) == c.DuckDBError) {
    return error.QueryFailed;
}
defer c.duckdb_destroy_prepare(&stmt);
```

**ArrayListUnmanaged** (Zig 0.15+):
```zig
var list: std.ArrayListUnmanaged(T) = .{};
defer list.deinit(allocator);
list.append(allocator, item) catch {};
```

## Swift Code Style

**C Interop** - `@_cdecl` for exports, `@convention(c)` for callbacks:
```swift
@_cdecl("check_accessibility")
public func check_accessibility() -> Bool { ... }

public typealias EventCallback = @convention(c) (
    UnsafePointer<CChar>?, Int32
) -> Void
```

## Testing

### TDD - Chicago/Detroit Style

We follow **Chicago-style TDD** (also called Detroit or Classical TDD):

1. **Write the test first** - Start with a failing test that describes the behavior
2. **Test behavior, not implementation** - Tests verify what the code does, not how
3. **Use real collaborators** - Prefer real objects over mocks; use in-memory databases
4. **Refactor with confidence** - Tests protect against regressions

**Workflow**:
```
1. Write a failing test
2. Write minimal code to make it pass
3. Refactor (tests still pass)
4. Commit
5. Repeat
```

**Test naming** - `Module.function description`:
```zig
test "RulesEngine finds matching rule" { ... }
test "Event.eql returns false for different app" { ... }
```

**Structure** - Setup → Action → Assert:
```zig
test "HierarchyImporter imports full hierarchy" {
    const conn = try openInMemoryDb();  // Setup
    try setupDb(conn);
    var importer = HierarchyImporter.init(conn, std.testing.allocator);
    
    const stats = try importer.importFromJson(json);  // Action
    
    try std.testing.expectEqual(@as(u32, 1), stats.customers);  // Assert
}
```

**Database tests** - Use in-memory DuckDB (`:memory:`) with real migrations.

## Git Workflow

### Commit Frequently

- **Commit after each meaningful change** - Don't batch unrelated changes
- **Commit when tests pass** - Green tests = safe commit point
- **Small, focused commits** - Easier to review and revert if needed

### Conventional Commits

Format: `type: description`

- `feat:` - New feature
- `fix:` - Bug fix
- `chore:` - Maintenance, refactoring
- `docs:` - Documentation only

**Example**:
```
feat: add global rules that resolve kind by name in current project

- Add migration for is_global flag and kind_name column
- Global rules look up kind by name in current project
```

### Commit Message Guidelines

- First line: concise summary (50 chars or less ideal)
- Body: explain *why*, not *what* (the diff shows what)
- Reference issue numbers if applicable

## Key Patterns

**Interactive picker**:
```zig
var p = picker.Picker.init(allocator, items, "Title") catch |err| {
    if (err == picker.PickerError.NotATty) { /* handle */ }
    return;
};
defer p.deinit();
const selection = p.run() catch return;
```

**JSON parsing**:
```zig
const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
    return error.ParseError;
};
defer parsed.deinit();
```

## Debugging

- Database: `~/.local/share/time-tracker/tracker.db`
- Query: `duckdb <db_path> "SELECT ..."`
- Stop daemon before querying (it holds DB lock)
- WiFi needs Location Services (falls back to system_profiler)
