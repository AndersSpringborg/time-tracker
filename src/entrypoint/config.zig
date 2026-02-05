//! Configuration system for Time Tracker
//!
//! Manages user settings stored in ~/.config/time-tracker/config.json

const std = @import("std");

/// Configuration settings for Time Tracker
pub const Config = struct {
    /// WiFi SSID that triggers tracking (null = track on all networks)
    tracking_wifi: ?[]const u8 = null,
    /// Whether tracking is globally enabled
    enabled: bool = true,

    /// Free any allocated memory
    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.tracking_wifi) |wifi| {
            allocator.free(wifi);
        }
        self.tracking_wifi = null;
    }
};

pub const ConfigError = error{
    OutOfMemory,
    FileReadError,
    FileWriteError,
    ParseError,
    PathTooLong,
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

        if (obj.get("tracking_wifi")) |wifi_value| {
            if (wifi_value == .string) {
                config.tracking_wifi = allocator.dupe(u8, wifi_value.string) catch return error.OutOfMemory;
            }
        }

        if (obj.get("enabled")) |enabled_value| {
            if (enabled_value == .bool) {
                config.enabled = enabled_value.bool;
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

    // Build JSON content
    var content_buf: [1024]u8 = undefined;
    var content_len: usize = 0;

    // Start JSON object
    const header = "{\n";
    @memcpy(content_buf[content_len..][0..header.len], header);
    content_len += header.len;

    // Add tracking_wifi
    if (cfg.tracking_wifi) |wifi| {
        const wifi_line = std.fmt.bufPrint(content_buf[content_len..], "  \"tracking_wifi\": \"{s}\",\n", .{wifi}) catch return error.FileWriteError;
        content_len += wifi_line.len;
    } else {
        const null_line = "  \"tracking_wifi\": null,\n";
        @memcpy(content_buf[content_len..][0..null_line.len], null_line);
        content_len += null_line.len;
    }

    // Add enabled
    const enabled_line = std.fmt.bufPrint(content_buf[content_len..], "  \"enabled\": {}\n", .{cfg.enabled}) catch return error.FileWriteError;
    content_len += enabled_line.len;

    // Close JSON object
    const footer = "}\n";
    @memcpy(content_buf[content_len..][0..footer.len], footer);
    content_len += footer.len;

    // Write to file
    _ = file.pwriteAll(content_buf[0..content_len], 0) catch return error.FileWriteError;
}

/// Get a specific config value as a string (for CLI display)
pub fn getValue(allocator: std.mem.Allocator, key: []const u8) ConfigError!?[]const u8 {
    const config = try load(allocator);
    defer {
        var mutable_config = config;
        mutable_config.deinit(allocator);
    }

    if (std.mem.eql(u8, key, "tracking-wifi") or std.mem.eql(u8, key, "tracking_wifi")) {
        if (config.tracking_wifi) |wifi| {
            return allocator.dupe(u8, wifi) catch return error.OutOfMemory;
        }
        return null;
    } else if (std.mem.eql(u8, key, "enabled")) {
        return if (config.enabled)
            allocator.dupe(u8, "true") catch return error.OutOfMemory
        else
            allocator.dupe(u8, "false") catch return error.OutOfMemory;
    }

    return null;
}

/// Set a specific config value from string
pub fn setValue(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ConfigError!void {
    var config = try load(allocator);
    defer config.deinit(allocator);

    if (std.mem.eql(u8, key, "tracking-wifi") or std.mem.eql(u8, key, "tracking_wifi")) {
        if (config.tracking_wifi) |old| {
            allocator.free(old);
        }
        config.tracking_wifi = allocator.dupe(u8, value) catch return error.OutOfMemory;
    } else if (std.mem.eql(u8, key, "enabled")) {
        config.enabled = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
    }

    try save(allocator, config);
}

/// Unset a specific config value (return to default)
pub fn unsetValue(allocator: std.mem.Allocator, key: []const u8) ConfigError!void {
    var config = try load(allocator);
    defer config.deinit(allocator);

    if (std.mem.eql(u8, key, "tracking-wifi") or std.mem.eql(u8, key, "tracking_wifi")) {
        if (config.tracking_wifi) |old| {
            allocator.free(old);
        }
        config.tracking_wifi = null;
    } else if (std.mem.eql(u8, key, "enabled")) {
        config.enabled = true; // default
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

    var entries = allocator.alloc(ConfigEntry, 2) catch return error.OutOfMemory;

    entries[0] = ConfigEntry{
        .key = "tracking-wifi",
        .value = if (config.tracking_wifi) |wifi|
            allocator.dupe(u8, wifi) catch return error.OutOfMemory
        else
            null,
        .description = "WiFi SSID that triggers tracking (null = all networks)",
    };

    entries[1] = ConfigEntry{
        .key = "enabled",
        .value = if (config.enabled)
            allocator.dupe(u8, "true") catch return error.OutOfMemory
        else
            allocator.dupe(u8, "false") catch return error.OutOfMemory,
        .description = "Whether tracking is globally enabled",
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
    try std.testing.expectEqual(@as(?[]const u8, null), config.tracking_wifi);
    try std.testing.expect(config.enabled);
}

test "parseConfig empty content returns defaults" {
    const config = try parseConfig(std.testing.allocator, "");
    try std.testing.expectEqual(@as(?[]const u8, null), config.tracking_wifi);
    try std.testing.expect(config.enabled);
}

test "parseConfig valid JSON" {
    const json =
        \\{
        \\  "tracking_wifi": "MyNetwork",
        \\  "enabled": false
        \\}
    ;
    var config = try parseConfig(std.testing.allocator, json);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("MyNetwork", config.tracking_wifi.?);
    try std.testing.expect(!config.enabled);
}

test "parseConfig null wifi" {
    const json =
        \\{
        \\  "tracking_wifi": null,
        \\  "enabled": true
        \\}
    ;
    var config = try parseConfig(std.testing.allocator, json);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?[]const u8, null), config.tracking_wifi);
    try std.testing.expect(config.enabled);
}

test "parseConfig invalid JSON returns error" {
    const result = parseConfig(std.testing.allocator, "not valid json");
    try std.testing.expectError(error.ParseError, result);
}
