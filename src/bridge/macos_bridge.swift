import Cocoa
import ApplicationServices

// Callback type for Zig to receive events
public typealias EventCallback = @convention(c) (
    UnsafePointer<CChar>?,  // app_name
    UnsafePointer<CChar>?,  // window_title
    Int32                    // error_code: 0=ok, 1=permission_denied
) -> Void

var globalCallback: EventCallback?
var lastApp: NSRunningApplication?

// --- EXPORTED FUNCTIONS ---

@_cdecl("check_accessibility")
public func check_accessibility() -> Bool {
    return AXIsProcessTrusted()
}

@_cdecl("start_listening")
public func start_listening(callback: EventCallback) {
    globalCallback = callback
    
    // Check permissions first
    if !AXIsProcessTrusted() {
        "".withCString { empty in
            callback(empty, empty, 1)  // error_code = 1 (permission denied)
        }
        return
    }
    
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
    CFRunLoopRun()
}

// --- INTERNAL LOGIC ---

func handleAppChange(_ app: NSRunningApplication) {
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
    
    // Call back to Zig
    appName.withCString { cApp in
        windowTitle.withCString { cTitle in
            globalCallback?(cApp, cTitle, 0)  // error_code = 0 (success)
        }
    }
}
