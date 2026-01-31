This is a comprehensive architectural plan for building your Low-Power, Event-Driven Time Tracker Daemon.

We will use the Hybrid Architecture: A single statically compiled binary where Zig is the brain (managing state, DB, and logic) and Swift is the sensor (handling macOS APIs).

1. High-Level Architecture
The Sensor (Swift): A small, compiled object file linked into the binary. It hooks into the macOS NSRunLoop to listen for window changes and queries WiFi. It costs 0% CPU when idle.

The Brain (Zig): The main entry point. It launches the Swift listener on a thread, receives callbacks, enriches data, and writes to storage.

The Storage (DuckDB): An embedded SQL database running in WAL (Write-Ahead-Log) mode to allow concurrent reading by your TUI/Dashboard.

2. The Data Schema (DuckDB)
Before writing code, we define what we are storing. We need a "Time Series" table.

File: tracker.db

SQL
CREATE TABLE IF NOT EXISTS events (
    timestamp TIMESTAMP DEFAULT current_timestamp,
    event_type VARCHAR,        -- 'focus_change', 'title_change', 'wifi_change', 'idle'
    app_name VARCHAR,          -- 'IntelliJ IDEA', 'Google Chrome'
    window_title VARCHAR,      -- 'main.zig - Project A', 'GitHub - Pull Requests'
    wifi_ssid VARCHAR,         -- 'Home_5G', 'Starbucks_Guest'
    duration_ms INTEGER        -- Calculated duration of the *previous* state
);
3. Component A: The "Sensor" (src/macos_bridge.swift)
This Swift file does two things:

Passive Listening: Watches for app switches and window title changes.

Active Querying: Fetches the current WiFi SSID when asked.

It exports C-compatible functions so Zig can use them directly.

Swift
import Cocoa
import CoreWLAN
import ApplicationServices

// 1. Define the Callback type Zig will provide
public typealias StateCallback = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void

var globalCallback: StateCallback?
var lastApp: NSRunningApplication?
var lastObserver: AXObserver?

// --- EXPORTED FUNCTIONS ---

@_cdecl("start_listening")
public func start_listening(callback: StateCallback) {
    globalCallback = callback

    // Watch for App Switches (Global)
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
    ) { note in
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        handleAppChange(app)
    }

    // Start RunLoop
    CFRunLoopRun()
}

@_cdecl("get_wifi_ssid")
public func get_wifi_ssid() -> UnsafePointer<CChar>? {
    let client = CWWiFiClient.shared()
    if let ssid = client.interface()?.ssid() {
        // Return a strdup so Zig can own/free the memory or just read it.
        // For simplicity, we return a swift-managed pointer (be careful with lifetime)
        // or better: copy it to a static buffer.
        return (ssid as NSString).utf8String
    }
    return nil
}

// --- INTERNAL LOGIC ---

func handleAppChange(_ app: NSRunningApplication) {
    lastApp = app
    
    // 1. Report immediately
    report(app)

    // 2. Attach Window Title Observer
    let pid = app.processIdentifier
    var observer: AXObserver?
    guard AXObserverCreate(pid, axCallback, &observer) == .success, let obs = observer else { return }
    lastObserver = obs
    
    let appElem = AXUIElementCreateApplication(pid)
    AXObserverAddNotification(obs, appElem, kAXTitleChangedNotification as CFString, nil)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
}

func axCallback(observer: AXObserver, element: AXUIElement, notification: CFString, refcon: UnsafeMutableRawPointer?) {
    if let app = lastApp { report(app) }
}

func report(_ app: NSRunningApplication) {
    let appName = app.localizedName ?? "Unknown"
    
    // Get Window Title via Accessibility API
    var title: AnyObject?
    let appElem = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &title)
    
    // Safety check: if title is nil, send empty string
    // Pass strings to Zig
    appName.withCString { cApp in
        // (Simplified title extraction logic)
        (title as? String ?? "").withCString { cTitle in
            globalCallback?(cApp, cTitle)
        }
    }
}
4. Component B: The "Brain" (src/main.zig)
This is your Daemon. It imports the Swift functions, connects to DuckDB, and manages the loop.

Code snippet
const std = @import("std");
const duck = @cImport(@cInclude("duckdb.h")); // Requires duckdb.h in include path

// Import functions from Swift
extern fn start_listening(cb: *const fn ([*c]const u8, [*c]const u8) callconv(.C) void) void;
extern fn get_wifi_ssid() ?[*c]const u8;

// Global DB Connection (Simplified)
var db: duck.duckdb_database = undefined;
var conn: duck.duckdb_connection = undefined;

// The Callback that Swift calls
fn on_event_received(c_app: [*c]const u8, c_title: [*c]const u8) callconv(.C) void {
    const app = std.mem.span(c_app);
    const title = std.mem.span(c_title);
    
    // 1. Get Context (WiFi)
    var ssid_slice: []const u8 = "Offline";
    if (get_wifi_ssid()) |c_ssid| {
        ssid_slice = std.mem.span(c_ssid);
    }

    std.debug.print("EVENT: [{s}] App: {s} | Title: {s}\n", .{ssid_slice, app, title});

    // 2. Write to DuckDB
    // (In production: Use prepared statements!)
    var query_buf: [1024]u8 = undefined;
    const query = std.fmt.bufPrintZ(&query_buf, 
        "INSERT INTO events (event_type, app_name, window_title, wifi_ssid) VALUES ('focus', '{s}', '{s}', '{s}')",
        .{app, title, ssid_slice}
    ) catch return;

    _ = duck.duckdb_query(conn, query, null);
}

pub fn main() !void {
    // 1. Initialize DuckDB
    if (duck.duckdb_open("tracker.db", &db) == duck.DuckDBError) {
        std.debug.print("Failed to open DB\n", .{});
        return;
    }
    if (duck.duckdb_connect(db, &conn) == duck.DuckDBError) return;
    
    // Create Table
    _ = duck.duckdb_query(conn, "CREATE TABLE IF NOT EXISTS events (ts TIMESTAMP DEFAULT current_timestamp, app_name VARCHAR, window_title VARCHAR, wifi_ssid VARCHAR, event_type VARCHAR);", null);

    std.debug.print("Daemon Started. Listening for events...\n", .{});

    // 2. Hand control over to the Swift RunLoop (Blocking)
    start_listening(on_event_received);
    
    // Cleanup (unreachable usually)
    duck.duckdb_disconnect(&conn);
    duck.duckdb_close(&db);
}
5. Component C: The Build System (build.zig)
This is the glue that makes zig build handle the Swift compilation automatically.

Code snippet
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "tracker-daemon",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- 1. Compile Swift Bridge ---
    // We invoke swiftc manually to produce an object file
    const swift_cmd = b.addSystemCommand(&.{
        "swiftc",
        "-emit-object",
        "-parse-as-library",
        "-o", "macos_bridge.o",
        "src/macos_bridge.swift"
    });
    
    // Ensure Swift compiles before linking
    exe.step.dependOn(&swift_cmd.step);
    exe.addObjectFile(b.path("macos_bridge.o"));

    // --- 2. Link Frameworks ---
    exe.linkFramework("Foundation");
    exe.linkFramework("Cocoa");
    exe.linkFramework("CoreWLAN");
    exe.linkFramework("ApplicationServices");

    // --- 3. Link DuckDB ---
    // Assuming you have libduckdb.dylib or .a installed
    exe.linkSystemLibrary("duckdb");
    exe.linkLibC();

    b.installArtifact(exe);
}
6. Execution Plan
Install Dependencies:

Install Zig.

Install DuckDB (brew install duckdb or download the libduckdb C-API files).

Create Files:

Put the code above into src/main.zig, src/macos_bridge.swift, and build.zig.

Build:

Run zig build. This will call the Swift compiler, then the Zig compiler, and link them.

Permissions:

The first time you run ./zig-out/bin/tracker-daemon, macOS will block it.

Go to Privacy & Security > Accessibility and add your Terminal (or the binary itself).

Deploy:

Create the launchd plist to run this binary on login.

Why this architecture rocks:
Zero Polling: It doesn't wake up every 5 seconds. It wakes up only when you actually switch windows.

Zero Overhead: The swift NSRunLoop is highly optimized by Apple.

Full Context: You get WiFi SSID (environment) + App + Window Title.

Single Binary: No complex Python scripts or Node modules. Just one binary and one DB file.
