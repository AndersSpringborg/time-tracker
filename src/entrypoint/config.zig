//! Configuration system for Time Tracker
//!
//! Manages user settings stored in ~/.config/time-tracker/config.json

const std = @import("std");
const glob = @import("glob");

/// Configuration settings for Time Tracker
pub const Config = struct {
    /// List of WiFi patterns that trigger tracking (empty = track on all networks)
    /// Supports glob patterns: * matches any sequence, ? matches single char
    work_wifis: []const []const u8 = &[_][]const u8{},
    /// Whether tracking is globally enabled
    enabled: bool = true,
    /// Minimum persistence in minutes before switching weighted project focus
    weighted_switch_minutes: i64 = 10,

    /// Free any allocated memory
    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.work_wifis) |wifi| {
            allocator.free(wifi);
        }
        if (self.work_wifis.len > 0) {
            allocator.free(self.work_wifis);
        }
        self.work_wifis = &[_][]const u8{};
    }

    /// Check if a WiFi SSID matches any configured work WiFi pattern
    pub fn matchesWorkWifi(self: *const Config, ssid: []const u8) bool {
        if (self.work_wifis.len == 0) {
            // No patterns configured = track everywhere
            return true;
        }

        for (self.work_wifis) |pattern| {
            if (glob.match(pattern, ssid)) {
                return true;
            }
        }
        return false;
    }
};

pub const ConfigError = error{
    OutOfMemory,
    FileReadError,
    FileWriteError,
    ParseError,
    PathTooLong,
    InvalidValue,
};

/// Get the config file path (~/.config/time-tracker/config.json)
pub fn getConfigPath(allocator: std.mem.Allocator) ConfigError![]const u8 {
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const xdg_config = std.posix.getenv("XDG_CONFIG_HOME");

    var path_buf: [512]u8 = undefined;
    var dir_path: []const u8 = undefined;

    if (xdg_config) |config_dir| {
        dir_path = std.fmt.bufPrint(&path_buf, "{s}/time-tracker", .{config_dir}) catch return error.PathTooLong;
    } else {
        dir_path = std.fmt.bufPrint(&path_buf, "{s}/.config/time-tracker", .{home}) catch return error.PathTooLong;
    }

    // Create directory if it doesn't exist
    std.fs.makeDirAbsolute(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            // Try to create parent .config directory first
            const parent_end = std.mem.lastIndexOf(u8, dir_path, "/") orelse 0;
            if (parent_end > 0) {
                std.fs.makeDirAbsolute(dir_path[0..parent_end]) catch {};
                std.fs.makeDirAbsolute(dir_path) catch {};
            }
        }
    };

    return std.fmt.allocPrint(allocator, "{s}/config.json", .{dir_path}) catch return error.OutOfMemory;
}

/// Load configuration from disk
pub fn load(allocator: std.mem.Allocator) ConfigError!Config {
    const path = try getConfigPath(allocator);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch {
        // File doesn't exist - return defaults
        return Config{};
    };
    defer file.close();

    const stat = file.stat() catch return error.FileReadError;
    if (stat.size == 0) {
        return Config{};
    }

    const content = allocator.alloc(u8, stat.size) catch return error.OutOfMemory;
    defer allocator.free(content);

    _ = file.preadAll(content, 0) catch return error.FileReadError;

    return parseConfig(allocator, content);
}

/// Parse config from JSON content
fn parseConfig(allocator: std.mem.Allocator, content: []const u8) ConfigError!Config {
    if (content.len == 0) {
        return Config{};
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return error.ParseError;
    };
    defer parsed.deinit();

    var config = Config{};

    if (parsed.value == .object) {
        const obj = parsed.value.object;

        // Parse work_wifis array
        if (obj.get("work_wifis")) |wifis_value| {
            if (wifis_value == .array) {
                var wifi_list: std.ArrayListUnmanaged([]const u8) = .empty;
                errdefer {
                    for (wifi_list.items) |w| allocator.free(w);
                    wifi_list.deinit(allocator);
                }

                for (wifis_value.array.items) |item| {
                    if (item == .string) {
                        const wifi = allocator.dupe(u8, item.string) catch return error.OutOfMemory;
                        wifi_list.append(allocator, wifi) catch return error.OutOfMemory;
                    }
                }

                config.work_wifis = wifi_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
            }
        } else if (obj.get("tracking_wifi")) |wifi_value| {
            // Backwards compatibility: migrate old tracking_wifi to work_wifis
            if (wifi_value == .string) {
                var wifi_list = allocator.alloc([]const u8, 1) catch return error.OutOfMemory;
                wifi_list[0] = allocator.dupe(u8, wifi_value.string) catch {
                    allocator.free(wifi_list);
                    return error.OutOfMemory;
                };
                config.work_wifis = wifi_list;
            }
        }

        if (obj.get("enabled")) |enabled_value| {
            if (enabled_value == .bool) {
                config.enabled = enabled_value.bool;
            }
        }

        if (obj.get("weighted_switch_minutes")) |switch_value| {
            switch (switch_value) {
                .integer => |v| {
                    if (v > 0) config.weighted_switch_minutes = v;
                },
                else => {},
            }
        }
    }

    return config;
}

/// Save configuration to disk
pub fn save(allocator: std.mem.Allocator, cfg: Config) ConfigError!void {
    const path = try getConfigPath(allocator);
    defer allocator.free(path);

    const file = std.fs.createFileAbsolute(path, .{}) catch return error.FileWriteError;
    defer file.close();

    // Build JSON content dynamically
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);

    // Start JSON object
    content.appendSlice(allocator, "{\n") catch return error.OutOfMemory;

    // Add work_wifis array
    content.appendSlice(allocator, "  \"work_wifis\": [") catch return error.OutOfMemory;
    for (cfg.work_wifis, 0..) |wifi, i| {
        if (i > 0) {
            content.appendSlice(allocator, ", ") catch return error.OutOfMemory;
        }
        content.append(allocator, '"') catch return error.OutOfMemory;
        // Escape any special JSON characters in the WiFi name
        for (wifi) |ch| {
            switch (ch) {
                '"' => content.appendSlice(allocator, "\\\"") catch return error.OutOfMemory,
                '\\' => content.appendSlice(allocator, "\\\\") catch return error.OutOfMemory,
                '\n' => content.appendSlice(allocator, "\\n") catch return error.OutOfMemory,
                '\r' => content.appendSlice(allocator, "\\r") catch return error.OutOfMemory,
                '\t' => content.appendSlice(allocator, "\\t") catch return error.OutOfMemory,
                else => content.append(allocator, ch) catch return error.OutOfMemory,
            }
        }
        content.append(allocator, '"') catch return error.OutOfMemory;
    }
    content.appendSlice(allocator, "],\n") catch return error.OutOfMemory;

    // Add enabled
    const enabled_str = if (cfg.enabled) "true" else "false";
    content.appendSlice(allocator, "  \"enabled\": ") catch return error.OutOfMemory;
    content.appendSlice(allocator, enabled_str) catch return error.OutOfMemory;
    content.appendSlice(allocator, ",\n") catch return error.OutOfMemory;

    // Add weighted report settings
    content.appendSlice(allocator, "  \"weighted_switch_minutes\": ") catch return error.OutOfMemory;
    const switch_str = std.fmt.allocPrint(allocator, "{d}", .{cfg.weighted_switch_minutes}) catch return error.OutOfMemory;
    defer allocator.free(switch_str);
    content.appendSlice(allocator, switch_str) catch return error.OutOfMemory;
    content.appendSlice(allocator, "\n") catch return error.OutOfMemory;

    // Close JSON object
    content.appendSlice(allocator, "}\n") catch return error.OutOfMemory;

    // Write to file
    _ = file.pwriteAll(content.items, 0) catch return error.FileWriteError;
}

/// Add a WiFi pattern to the work_wifis list
pub fn addWorkWifi(allocator: std.mem.Allocator, pattern: []const u8) ConfigError!void {
    var config = try load(allocator);
    defer config.deinit(allocator);

    // Check if pattern already exists
    for (config.work_wifis) |existing| {
        if (std.mem.eql(u8, existing, pattern)) {
            // Already exists, nothing to do
            return;
        }
    }

    // Create new array with added pattern
    var new_wifis = allocator.alloc([]const u8, config.work_wifis.len + 1) catch return error.OutOfMemory;
    errdefer allocator.free(new_wifis);

    // Copy existing patterns
    for (config.work_wifis, 0..) |wifi, i| {
        new_wifis[i] = allocator.dupe(u8, wifi) catch return error.OutOfMemory;
    }

    // Add new pattern
    new_wifis[config.work_wifis.len] = allocator.dupe(u8, pattern) catch return error.OutOfMemory;

    // Free old array and update config
    for (config.work_wifis) |wifi| {
        allocator.free(wifi);
    }
    if (config.work_wifis.len > 0) {
        allocator.free(config.work_wifis);
    }
    config.work_wifis = new_wifis;

    try save(allocator, config);
}

/// Remove a WiFi pattern from the work_wifis list
pub fn removeWorkWifi(allocator: std.mem.Allocator, pattern: []const u8) ConfigError!bool {
    var cfg = try load(allocator);
    defer cfg.deinit(allocator);

    // Find the pattern
    var found_idx: ?usize = null;
    for (cfg.work_wifis, 0..) |existing, i| {
        if (std.mem.eql(u8, existing, pattern)) {
            found_idx = i;
            break;
        }
    }

    if (found_idx == null) {
        return false; // Pattern not found
    }

    if (cfg.work_wifis.len == 1) {
        // Last pattern - set empty and let deinit clean up the old data
        // Note: cfg.deinit will free the old work_wifis
        const new_config = Config{
            .enabled = cfg.enabled,
            .weighted_switch_minutes = cfg.weighted_switch_minutes,
        };
        try save(allocator, new_config);
    } else {
        // Create new array without the pattern
        var new_wifis = allocator.alloc([]const u8, cfg.work_wifis.len - 1) catch return error.OutOfMemory;
        errdefer allocator.free(new_wifis);

        var new_idx: usize = 0;
        for (cfg.work_wifis, 0..) |wifi, i| {
            if (i == found_idx.?) {
                continue; // Skip the one being removed
            }
            new_wifis[new_idx] = allocator.dupe(u8, wifi) catch return error.OutOfMemory;
            new_idx += 1;
        }

        // Save with new array
        const new_config = Config{
            .work_wifis = new_wifis,
            .enabled = cfg.enabled,
            .weighted_switch_minutes = cfg.weighted_switch_minutes,
        };
        try save(allocator, new_config);

        // Free the duplicated strings and array (we don't need them after save)
        for (new_wifis) |wifi| {
            allocator.free(wifi);
        }
        allocator.free(new_wifis);
    }

    return true;
}

/// Get all work WiFi patterns
pub fn getWorkWifis(allocator: std.mem.Allocator) ConfigError![]const []const u8 {
    var cfg = try load(allocator);
    defer cfg.deinit(allocator);

    // Duplicate everything so caller owns it
    var result = allocator.alloc([]const u8, cfg.work_wifis.len) catch return error.OutOfMemory;
    for (cfg.work_wifis, 0..) |wifi, i| {
        result[i] = allocator.dupe(u8, wifi) catch return error.OutOfMemory;
    }

    return result;
}

/// Free work wifis returned by getWorkWifis
pub fn freeWorkWifis(allocator: std.mem.Allocator, wifis: []const []const u8) void {
    for (wifis) |wifi| {
        allocator.free(wifi);
    }
    allocator.free(wifis);
}

/// Get a specific config value as a string (for CLI display)
pub fn getValue(allocator: std.mem.Allocator, key: []const u8) ConfigError!?[]const u8 {
    const config = try load(allocator);
    defer {
        var mutable_config = config;
        mutable_config.deinit(allocator);
    }

    if (std.mem.eql(u8, key, "work-wifis") or std.mem.eql(u8, key, "work_wifis")) {
        if (config.work_wifis.len == 0) {
            return null;
        }
        // Return comma-separated list
        var total_len: usize = 0;
        for (config.work_wifis) |wifi| {
            total_len += wifi.len + 2; // ", "
        }
        var result = allocator.alloc(u8, total_len) catch return error.OutOfMemory;
        var pos: usize = 0;
        for (config.work_wifis, 0..) |wifi, i| {
            if (i > 0) {
                @memcpy(result[pos..][0..2], ", ");
                pos += 2;
            }
            @memcpy(result[pos..][0..wifi.len], wifi);
            pos += wifi.len;
        }
        return result[0..pos];
    } else if (std.mem.eql(u8, key, "enabled")) {
        return if (config.enabled)
            allocator.dupe(u8, "true") catch return error.OutOfMemory
        else
            allocator.dupe(u8, "false") catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, key, "weighted-switch-minutes") or std.mem.eql(u8, key, "weighted_switch_minutes")) {
        return std.fmt.allocPrint(allocator, "{d}", .{config.weighted_switch_minutes}) catch return error.OutOfMemory;
    }

    return null;
}

/// Set a specific config value from string
pub fn setValue(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ConfigError!void {
    var config = try load(allocator);
    defer config.deinit(allocator);

    if (std.mem.eql(u8, key, "enabled")) {
        config.enabled = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "weighted-switch-minutes") or std.mem.eql(u8, key, "weighted_switch_minutes")) {
        const parsed = std.fmt.parseInt(i64, value, 10) catch return error.InvalidValue;
        if (parsed <= 0) return error.InvalidValue;
        config.weighted_switch_minutes = parsed;
    }
    // Note: work_wifis should be managed via addWorkWifi/removeWorkWifi

    try save(allocator, config);
}

/// Unset a specific config value (return to default)
pub fn unsetValue(allocator: std.mem.Allocator, key: []const u8) ConfigError!void {
    var config = try load(allocator);
    defer config.deinit(allocator);

    if (std.mem.eql(u8, key, "work-wifis") or std.mem.eql(u8, key, "work_wifis")) {
        for (config.work_wifis) |wifi| {
            allocator.free(wifi);
        }
        if (config.work_wifis.len > 0) {
            allocator.free(config.work_wifis);
        }
        config.work_wifis = &[_][]const u8{};
    } else if (std.mem.eql(u8, key, "enabled")) {
        config.enabled = true; // default
    } else if (std.mem.eql(u8, key, "weighted-switch-minutes") or std.mem.eql(u8, key, "weighted_switch_minutes")) {
        config.weighted_switch_minutes = 10;
    }

    try save(allocator, config);
}

/// List all config values
pub fn listAll(allocator: std.mem.Allocator) ConfigError![]const ConfigEntry {
    const config = try load(allocator);
    defer {
        var mutable_config = config;
        mutable_config.deinit(allocator);
    }

    var entries = allocator.alloc(ConfigEntry, 3) catch return error.OutOfMemory;

    // Build work_wifis display string
    var work_wifis_str: ?[]const u8 = null;
    if (config.work_wifis.len > 0) {
        var total_len: usize = 0;
        for (config.work_wifis) |wifi| {
            total_len += wifi.len + 2;
        }
        var result = allocator.alloc(u8, total_len) catch return error.OutOfMemory;
        var pos: usize = 0;
        for (config.work_wifis, 0..) |wifi, i| {
            if (i > 0) {
                @memcpy(result[pos..][0..2], ", ");
                pos += 2;
            }
            @memcpy(result[pos..][0..wifi.len], wifi);
            pos += wifi.len;
        }
        work_wifis_str = result[0..pos];
    }

    entries[0] = ConfigEntry{
        .key = "work-wifis",
        .value = work_wifis_str,
        .description = "WiFi patterns that trigger tracking (glob: * and ? supported)",
    };

    entries[1] = ConfigEntry{
        .key = "enabled",
        .value = if (config.enabled)
            allocator.dupe(u8, "true") catch return error.OutOfMemory
        else
            allocator.dupe(u8, "false") catch return error.OutOfMemory,
        .description = "Whether tracking is globally enabled",
    };

    entries[2] = ConfigEntry{
        .key = "weighted-switch-minutes",
        .value = std.fmt.allocPrint(allocator, "{d}", .{config.weighted_switch_minutes}) catch return error.OutOfMemory,
        .description = "Minutes required before switching project focus in weighted report",
    };

    return entries;
}

pub const ConfigEntry = struct {
    key: []const u8,
    value: ?[]const u8,
    description: []const u8,

    pub fn deinit(self: *ConfigEntry, allocator: std.mem.Allocator) void {
        if (self.value) |v| {
            allocator.free(v);
        }
    }
};

pub fn freeEntries(allocator: std.mem.Allocator, entries: []const ConfigEntry) void {
    for (entries) |entry| {
        if (entry.value) |v| {
            allocator.free(v);
        }
    }
    allocator.free(entries);
}

// ============================================================================
// Tests
// ============================================================================

test "Config default values" {
    const config = Config{};
    try std.testing.expectEqual(@as(usize, 0), config.work_wifis.len);
    try std.testing.expect(config.enabled);
    try std.testing.expectEqual(@as(i64, 10), config.weighted_switch_minutes);
}

test "Config.matchesWorkWifi empty list matches all" {
    const config = Config{};
    try std.testing.expect(config.matchesWorkWifi("AnyNetwork"));
    try std.testing.expect(config.matchesWorkWifi(""));
}

test "Config.matchesWorkWifi exact match" {
    var wifis = [_][]const u8{"HomeWifi"};
    const config = Config{ .work_wifis = &wifis };
    try std.testing.expect(config.matchesWorkWifi("HomeWifi"));
    try std.testing.expect(config.matchesWorkWifi("homewifi")); // case insensitive
    try std.testing.expect(!config.matchesWorkWifi("OfficeWifi"));
}

test "Config.matchesWorkWifi glob pattern" {
    var wifis = [_][]const u8{ "Office*", "Home-?" };
    const config = Config{ .work_wifis = &wifis };
    try std.testing.expect(config.matchesWorkWifi("Office-5G"));
    try std.testing.expect(config.matchesWorkWifi("Office"));
    try std.testing.expect(config.matchesWorkWifi("Home-A"));
    try std.testing.expect(!config.matchesWorkWifi("Home-AB")); // ? matches single char
    try std.testing.expect(!config.matchesWorkWifi("CoffeeShop"));
}

test "parseConfig empty content returns defaults" {
    const config = try parseConfig(std.testing.allocator, "");
    try std.testing.expectEqual(@as(usize, 0), config.work_wifis.len);
    try std.testing.expect(config.enabled);
}

test "parseConfig work_wifis array" {
    const json =
        \\{
        \\  "work_wifis": ["Home", "Office*"],
        \\  "enabled": false,
        \\  "weighted_switch_minutes": 7
        \\}
    ;
    var config = try parseConfig(std.testing.allocator, json);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), config.work_wifis.len);
    try std.testing.expectEqualStrings("Home", config.work_wifis[0]);
    try std.testing.expectEqualStrings("Office*", config.work_wifis[1]);
    try std.testing.expect(!config.enabled);
    try std.testing.expectEqual(@as(i64, 7), config.weighted_switch_minutes);
}

test "parseConfig backwards compatibility with tracking_wifi" {
    const json =
        \\{
        \\  "tracking_wifi": "OldNetwork",
        \\  "enabled": true
        \\}
    ;
    var config = try parseConfig(std.testing.allocator, json);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), config.work_wifis.len);
    try std.testing.expectEqualStrings("OldNetwork", config.work_wifis[0]);
    try std.testing.expect(config.enabled);
}

test "parseConfig invalid JSON returns error" {
    const result = parseConfig(std.testing.allocator, "not valid json");
    try std.testing.expectError(error.ParseError, result);
}
