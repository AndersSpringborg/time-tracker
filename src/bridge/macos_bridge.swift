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

// Menu bar status item
var statusItem: NSStatusItem?
var currentAppName: String = ""
var currentWindowTitle: String = ""

// --- EXPORTED FUNCTIONS ---

@_cdecl("check_accessibility")
public func check_accessibility() -> Bool {
    return AXIsProcessTrusted()
}

@_cdecl("get_wifi_ssid")
public func get_wifi_ssid() -> UnsafePointer<CChar>? {
    let client = CWWiFiClient.shared()
    if let ssid = client.interface()?.ssid() {
        return (ssid as NSString).utf8String
    }
    return nil
}

@_cdecl("start_listening")
public func start_listening(callback: EventCallback) {
    globalCallback = callback
    
    // Check permissions first
    if !AXIsProcessTrusted() {
        "".withCString { empty in
            callback(empty, empty, empty, 1)  // error_code = 1 (permission denied)
        }
        return
    }
    
    // Initialize NSApplication for menu bar support
    // This is needed for status bar items to work
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)  // No dock icon, just menu bar
    
    // Set up the menu bar item
    setupMenuBar()
    
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
    
    // Report initial state
    if let frontApp = NSWorkspace.shared.frontmostApplication {
        handleAppChange(frontApp)
    }
    
    // Start the RunLoop (blocks forever)
    app.run()
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
    let headerItem = NSMenuItem(title: "⏱ Time Tracker", action: nil, keyEquivalent: "")
    headerItem.isEnabled = false
    menu.addItem(headerItem)
    
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

// Helper class to handle menu actions
class MenuHelper: NSObject {
    static let shared = MenuHelper()
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// --- INTERNAL LOGIC ---

func getCurrentWifiSSID() -> String {
    let client = CWWiFiClient.shared()
    return client.interface()?.ssid() ?? ""
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
    
    // Update menu bar
    updateMenuBar(appName: appName, windowTitle: windowTitle)
    
    // Set up title change observer for this app
    setupTitleObserver(for: app)
    
    // Call back to Zig
    appName.withCString { cApp in
        windowTitle.withCString { cTitle in
            wifiSSID.withCString { cWifi in
                globalCallback?(cApp, cTitle, cWifi, 0)  // error_code = 0 (success)
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
        
        // Update menu bar
        updateMenuBar(appName: appName, windowTitle: windowTitle)
        
        appName.withCString { cApp in
            windowTitle.withCString { cTitle in
                wifiSSID.withCString { cWifi in
                    globalCallback?(cApp, cTitle, cWifi, 0)
                }
            }
        }
    }
}
