import Cocoa
import ApplicationServices
import CoreWLAN

// Callback type for Zig to receive events
public typealias EventCallback = @convention(c) (
    UnsafePointer<CChar>?,  // app_name
    UnsafePointer<CChar>?,  // window_title
    UnsafePointer<CChar>?,  // wifi_ssid
    Int32                    // error_code: 0=ok, 1=permission_denied
) -> Void

var globalCallback: EventCallback?
var lastApp: NSRunningApplication?
var lastObserver: AXObserver?
var workspaceObserverInstalled: Bool = false
var permissionPollTimer: Timer?
var permissionDeniedReported: Bool = false

// Menu bar status item
var statusItem: NSStatusItem?
var currentAppName: String = ""
var currentWindowTitle: String = ""

// Tracking state
var trackingPaused: Bool = false
var workWifiPatterns: [String] = []

// --- EXPORTED FUNCTIONS ---

@_cdecl("check_accessibility")
public func check_accessibility() -> Bool {
    return isAccessibilityTrusted()
}

@_cdecl("get_wifi_ssid")
public func get_wifi_ssid() -> UnsafePointer<CChar>? {
    let client = CWWiFiClient.shared()
    if let ssid = client.interface()?.ssid() {
        return (ssid as NSString).utf8String
    }
    return nil
}

@_cdecl("add_work_wifi")
public func add_work_wifi(_ pattern: UnsafePointer<CChar>?) {
    if let patternPtr = pattern {
        let patternStr = String(cString: patternPtr)
        if !workWifiPatterns.contains(patternStr) {
            workWifiPatterns.append(patternStr)
            NSLog("[TimeTracker] Added work WiFi pattern: %@", patternStr)
        }
    }
}

@_cdecl("clear_work_wifis")
public func clear_work_wifis() {
    workWifiPatterns.removeAll()
    trackingPaused = false
    NSLog("[TimeTracker] Cleared all work WiFi patterns - tracking on all networks")
}

// Current matched project/activity
var currentProject: String? = nil
var currentActivity: String? = nil

// Unmatched event count
var unmatchedEventCount: Int64 = 0

@_cdecl("update_matched_info")
public func update_matched_info(_ project: UnsafePointer<CChar>?, _ activity: UnsafePointer<CChar>?) {
    if let projectPtr = project, let activityPtr = activity {
        currentProject = String(cString: projectPtr)
        currentActivity = String(cString: activityPtr)
        updateMatchedInfoInMenu()
    }
}

@_cdecl("clear_matched_info")
public func clear_matched_info() {
    currentProject = nil
    currentActivity = nil
    updateMatchedInfoInMenu()
}

@_cdecl("update_unmatched_count")
public func update_unmatched_count(_ count: Int64) {
    unmatchedEventCount = count
    updateUnmatchedCountInMenu()
}

func updateUnmatchedCountInMenu() {
    DispatchQueue.main.async {
        guard let menu = statusItem?.menu else { return }
        
        if let unmatchedItem = menu.item(withTag: 105) {
            if unmatchedEventCount > 0 {
                unmatchedItem.title = "⚠️ \(unmatchedEventCount) events need rules"
                unmatchedItem.isHidden = false
            } else {
                unmatchedItem.isHidden = true
            }
        }
    }
}

func updateMatchedInfoInMenu() {
    DispatchQueue.main.async {
        guard let menu = statusItem?.menu else { return }
        
        // Update project (tag 103)
        if let projectItem = menu.item(withTag: 103) {
            if let project = currentProject {
                projectItem.title = "Project: \(project)"
                projectItem.isHidden = false
            } else {
                projectItem.title = "Project: (no match)"
                projectItem.isHidden = false
            }
        }
        
        // Update activity (tag 104)
        if let activityItem = menu.item(withTag: 104) {
            if let activity = currentActivity {
                activityItem.title = "Activity: \(activity)"
                activityItem.isHidden = false
            } else {
                activityItem.title = "Activity: (no match)"
                activityItem.isHidden = false
            }
        }
    }
}

@_cdecl("start_listening")
public func start_listening(callback: EventCallback) {
    globalCallback = callback

    // Initialize NSApplication for menu bar support
    // This is needed for status bar items to work
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)  // No dock icon, just menu bar

    // Set up the menu bar item
    setupMenuBar()

    if isAccessibilityTrusted() {
        beginTracking()
    } else {
        reportAccessibilityDenied()
        updatePermissionRequiredUI()
        startPermissionPoll()
    }

    // Start the RunLoop (blocks forever)
    app.run()
}

func beginTracking() {
    if !workspaceObserverInstalled {
        // Watch for app switches
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                  as? NSRunningApplication else { return }
            handleAppChange(app)
        }
        workspaceObserverInstalled = true
    }

    updateMenuBarIcon()

    // Report initial state
    if let frontApp = NSWorkspace.shared.frontmostApplication {
        handleAppChange(frontApp)
    }
}

func reportAccessibilityDenied() {
    guard !permissionDeniedReported else { return }
    permissionDeniedReported = true

    "".withCString { empty in
        globalCallback?(empty, empty, empty, 1)  // error_code = 1 (permission denied)
    }
}

func startPermissionPoll() {
    if permissionPollTimer != nil {
        return
    }

    permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
        if isAccessibilityTrusted() {
            timer.invalidate()
            permissionPollTimer = nil
            NSLog("[TimeTracker] Accessibility granted, enabling tracking")
            beginTracking()
        }
    }
}

func isAccessibilityTrusted() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
    let trustedWithOptions = AXIsProcessTrustedWithOptions(options)
    let trustedBasic = AXIsProcessTrusted()
    if trustedBasic != trustedWithOptions {
        NSLog("[TimeTracker] Accessibility trust mismatch basic=%@ options=%@", trustedBasic.description, trustedWithOptions.description)
    }
    return trustedWithOptions || trustedBasic
}

// --- MENU BAR ---

func setupMenuBar() {
    // Create the status item in the menu bar
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    
    if let button = statusItem?.button {
        button.image = NSImage(systemSymbolName: "clock.fill", accessibilityDescription: "Time Tracker")
        button.image?.isTemplate = true  // Adapts to light/dark mode
    }
    
    // Create the menu
    let menu = NSMenu()
    
    // Status header
    let headerItem = NSMenuItem(title: "Time Tracker", action: nil, keyEquivalent: "")
    headerItem.isEnabled = false
    menu.addItem(headerItem)
    
    // Tracking status (will be updated dynamically)
    let trackingStatusItem = NSMenuItem(title: "Status: Tracking", action: nil, keyEquivalent: "")
    trackingStatusItem.isEnabled = false
    trackingStatusItem.tag = 102  // Tag to find and update this item
    menu.addItem(trackingStatusItem)
    
    menu.addItem(NSMenuItem.separator())
    
    // Current tracking info (will be updated dynamically)
    let appItem = NSMenuItem(title: "App: -", action: nil, keyEquivalent: "")
    appItem.isEnabled = false
    appItem.tag = 100  // Tag to find and update this item
    menu.addItem(appItem)
    
    let windowItem = NSMenuItem(title: "Window: -", action: nil, keyEquivalent: "")
    windowItem.isEnabled = false
    windowItem.tag = 101  // Tag to find and update this item
    menu.addItem(windowItem)
    
    menu.addItem(NSMenuItem.separator())
    
    // Matched project/activity info
    let projectItem = NSMenuItem(title: "Project: (no match)", action: nil, keyEquivalent: "")
    projectItem.isEnabled = false
    projectItem.tag = 103
    menu.addItem(projectItem)
    
    let activityItem = NSMenuItem(title: "Activity: (no match)", action: nil, keyEquivalent: "")
    activityItem.isEnabled = false
    activityItem.tag = 104
    menu.addItem(activityItem)
    
    // Unmatched events count (hidden if 0)
    let unmatchedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    unmatchedItem.isEnabled = false
    unmatchedItem.tag = 105
    unmatchedItem.isHidden = true  // Hidden until we have unmatched events
    menu.addItem(unmatchedItem)
    
    menu.addItem(NSMenuItem.separator())
    
    // Quit option
    let quitItem = NSMenuItem(title: "Quit Time Tracker", action: #selector(MenuHelper.quitApp), keyEquivalent: "q")
    quitItem.target = MenuHelper.shared
    menu.addItem(quitItem)
    
    statusItem?.menu = menu
}

func updateMenuBar(appName: String, windowTitle: String) {
    currentAppName = appName
    currentWindowTitle = windowTitle
    
    DispatchQueue.main.async {
        guard let menu = statusItem?.menu else { return }
        
        // Update app name
        if let appItem = menu.item(withTag: 100) {
            let truncatedApp = String(appName.prefix(40))
            appItem.title = "App: \(truncatedApp)"
        }
        
        // Update window title
        if let windowItem = menu.item(withTag: 101) {
            let truncatedTitle = String(windowTitle.prefix(50))
            if truncatedTitle.isEmpty {
                windowItem.title = "Window: (no title)"
            } else if windowTitle.count > 50 {
                windowItem.title = "Window: \(truncatedTitle)..."
            } else {
                windowItem.title = "Window: \(truncatedTitle)"
            }
        }
    }
}

func updatePermissionRequiredUI() {
    DispatchQueue.main.async {
        guard let button = statusItem?.button, let menu = statusItem?.menu else { return }

        button.image = NSImage(systemSymbolName: "lock.trianglebadge.exclamationmark", accessibilityDescription: "Time Tracker")
        button.image?.isTemplate = true

        if let statusMenuItem = menu.item(withTag: 102) {
            statusMenuItem.title = "Status: Waiting for Accessibility permission"
        }
        if let appItem = menu.item(withTag: 100) {
            appItem.title = "App: (permission required)"
        }
        if let windowItem = menu.item(withTag: 101) {
            windowItem.title = "Window: Grant access in System Settings"
        }
    }
}

// Helper class to handle menu actions
class MenuHelper: NSObject {
    static let shared = MenuHelper()
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// --- INTERNAL LOGIC ---

// Cache WiFi SSID to avoid calling slow system_profiler on every event
var cachedWifiSSID: String = ""
var lastWifiCheck: Date = Date.distantPast
let wifiCacheInterval: TimeInterval = 30.0  // Refresh every 30 seconds

func getCurrentWifiSSID() -> String {
    // Return cached value if still fresh
    if Date().timeIntervalSince(lastWifiCheck) < wifiCacheInterval {
        return cachedWifiSSID
    }
    
    // Try CoreWLAN first (requires Location Services permission)
    let client = CWWiFiClient.shared()
    if let interface = client.interface(), let ssid = interface.ssid() {
        cachedWifiSSID = ssid
        lastWifiCheck = Date()
        return ssid
    }
    
    // Fallback to system_profiler (doesn't require Location permission, but slow)
    cachedWifiSSID = getWifiSSIDViaSystemProfiler()
    lastWifiCheck = Date()
    return cachedWifiSSID
}

func getWifiSSIDViaSystemProfiler() -> String {
    let task = Process()
    let pipe = Pipe()
    
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    task.arguments = ["SPAirPortDataType", "-detailLevel", "basic"]
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    
    do {
        try task.run()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            // Look for "Current Network Information:" section and get the network name on the next line
            let lines = output.components(separatedBy: "\n")
            var foundCurrentNetwork = false
            for line in lines {
                if line.contains("Current Network Information:") {
                    foundCurrentNetwork = true
                    continue
                }
                if foundCurrentNetwork {
                    // Next non-empty line after "Current Network Information:" is the SSID
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty && trimmed.hasSuffix(":") {
                        // Remove the trailing colon
                        let ssid = String(trimmed.dropLast())
                        if !ssid.isEmpty && ssid != "Network Type" {
                            return ssid
                        }
                    }
                    foundCurrentNetwork = false
                }
            }
        }
    } catch {
        NSLog("[TimeTracker] WiFi: system_profiler command failed: %@", error.localizedDescription)
    }
    
    return ""
}

/// Glob pattern matching (case-insensitive)
/// Supports * (any sequence) and ? (single character)
func matchGlob(pattern: String, text: String) -> Bool {
    let patternLower = pattern.lowercased()
    let textLower = text.lowercased()
    
    var pi = patternLower.startIndex
    var ti = textLower.startIndex
    var starIdx: String.Index? = nil
    var matchIdx: String.Index? = nil
    
    while ti < textLower.endIndex {
        if pi < patternLower.endIndex {
            let pc = patternLower[pi]
            let tc = textLower[ti]
            
            if pc == "*" {
                starIdx = pi
                matchIdx = ti
                pi = patternLower.index(after: pi)
                continue
            } else if pc == "?" || pc == tc {
                pi = patternLower.index(after: pi)
                ti = textLower.index(after: ti)
                continue
            }
        }
        
        // No match - backtrack if we have a star
        if let star = starIdx, let match = matchIdx {
            pi = patternLower.index(after: star)
            matchIdx = textLower.index(after: match)
            ti = matchIdx!
        } else {
            return false
        }
    }
    
    // Check remaining pattern is all stars
    while pi < patternLower.endIndex && patternLower[pi] == "*" {
        pi = patternLower.index(after: pi)
    }
    
    return pi >= patternLower.endIndex
}

/// Tracking is always active.
/// Work WiFi patterns are kept for context/analysis, not as a hard tracking gate.
func shouldTrack(currentWifi: String) -> Bool {
    _ = currentWifi
    return true
}

/// Update tracking state and menubar icon
func updateTrackingState(currentWifi: String) {
    let shouldBeTracking = shouldTrack(currentWifi: currentWifi)
    
    if trackingPaused != !shouldBeTracking {
        trackingPaused = !shouldBeTracking
        updateMenuBarIcon()
        
        if trackingPaused {
            NSLog("[TimeTracker] Tracking paused - not on configured WiFi")
        } else {
            NSLog("[TimeTracker] Tracking resumed - on configured WiFi")
        }
    }
}

/// Update the menubar icon and status text based on tracking state
func updateMenuBarIcon() {
    DispatchQueue.main.async {
        guard let button = statusItem?.button else { return }
        
        // Update icon
        let iconName = trackingPaused ? "clock.badge.xmark" : "clock.fill"
        button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Time Tracker")
        button.image?.isTemplate = true
        
        // Update status text in menu
        if let menu = statusItem?.menu, let statusMenuItem = menu.item(withTag: 102) {
            if trackingPaused {
                if !workWifiPatterns.isEmpty {
                    let patternsStr = workWifiPatterns.joined(separator: ", ")
                    statusMenuItem.title = "Status: Paused (not on \(patternsStr))"
                } else {
                    statusMenuItem.title = "Status: Paused"
                }
            } else {
                statusMenuItem.title = "Status: Tracking"
            }
        }
    }
}

func handleAppChange(_ app: NSRunningApplication) {
    // Remove old observer if exists
    if let obs = lastObserver {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }
    
    lastApp = app
    let appName = app.localizedName ?? "Unknown"
    
    // Get window title via Accessibility API
    let appElem = AXUIElementCreateApplication(app.processIdentifier)
    var windowValue: AnyObject?
    AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &windowValue)
    
    var titleValue: AnyObject?
    if let window = windowValue {
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue)
    }
    
    let windowTitle = (titleValue as? String) ?? ""
    let wifiSSID = getCurrentWifiSSID()
    
    // Update tracking state based on WiFi
    updateTrackingState(currentWifi: wifiSSID)
    
    // Update menu bar (always show current app/window)
    updateMenuBar(appName: appName, windowTitle: windowTitle)
    
    // Set up title change observer for this app
    setupTitleObserver(for: app)
    
    // Only call back to Zig if not paused
    if !trackingPaused {
        appName.withCString { cApp in
            windowTitle.withCString { cTitle in
                wifiSSID.withCString { cWifi in
                    globalCallback?(cApp, cTitle, cWifi, 0)  // error_code = 0 (success)
                }
            }
        }
    }
}

func setupTitleObserver(for app: NSRunningApplication) {
    let pid = app.processIdentifier
    var observer: AXObserver?
    
    guard AXObserverCreate(pid, axCallback, &observer) == .success, let obs = observer else { 
        return 
    }
    
    lastObserver = obs
    
    let appElem = AXUIElementCreateApplication(pid)
    
    // Get focused window and observe title changes
    var windowValue: AnyObject?
    AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &windowValue)
    
    if let window = windowValue {
        AXObserverAddNotification(obs, window as! AXUIElement, kAXTitleChangedNotification as CFString, nil)
    }
    
    // Also observe focused window changes within the app
    AXObserverAddNotification(obs, appElem, kAXFocusedWindowChangedNotification as CFString, nil)
    
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
}

func axCallback(observer: AXObserver, element: AXUIElement, notification: CFString, refcon: UnsafeMutableRawPointer?) {
    // Re-report current app when title changes
    if let app = lastApp {
        let appName = app.localizedName ?? "Unknown"
        
        // Get updated window title
        var titleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
        
        // If we got a window change, get the title from the new window
        if notification as String == kAXFocusedWindowChangedNotification as String {
            if let window = titleValue {
                var newTitle: AnyObject?
                AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &newTitle)
                titleValue = newTitle
            }
        }
        
        let windowTitle = (titleValue as? String) ?? ""
        let wifiSSID = getCurrentWifiSSID()
        
        // Update tracking state based on WiFi
        updateTrackingState(currentWifi: wifiSSID)
        
        // Update menu bar (always show current app/window)
        updateMenuBar(appName: appName, windowTitle: windowTitle)
        
        // Only call back to Zig if not paused
        if !trackingPaused {
            appName.withCString { cApp in
                windowTitle.withCString { cTitle in
                    wifiSSID.withCString { cWifi in
                        globalCallback?(cApp, cTitle, cWifi, 0)
                    }
                }
            }
        }
    }
}
