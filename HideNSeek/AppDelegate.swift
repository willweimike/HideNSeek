import Cocoa
import CoreGraphics
import SwiftUI
import ApplicationServices
import Combine
import ServiceManagement
import Foundation

@main
struct HideNSeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        MenuBarExtra("HideNSeek", image: "MenuBarIcon") {
            Button(action: appDelegate.openPopupWindow, label: { Text("Settings") })
            Divider()
            Button(action: appDelegate.openAccessibilityPreferences, label: { Text("Accessibility Preferences") })
            Button(action: appDelegate.openAutomationPreferences, label: { Text("Automation Preferences") })
            Divider()
            Button(action: appDelegate.quitApp, label: { Text("Quit") })
        }
    }
    
    init() {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            appDelegate.currentVersion = "\(version).\(build)"
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    struct Release: Codable {
        let tag_name: String
    }
    
    struct DockItem {
        let rect: NSRect
        let appID: String
    }
    
    
    var eventTap: CFMachPort?
    var mainWindow: NSWindow?
    var cancellables = Set<AnyCancellable>()
    var dockItems: [DockItem] = []
    var bundleIdDict: [String: String] = [:] // New dictionary for bundle IDs
    var currentVersion: String = ""
    
    private var mouseDownTime: CFTimeInterval = 0
    private var mouseDownLocation: CGPoint = .zero
    private var clickThreshold: CFTimeInterval = 0.5  // 500ms threshold
    private var pendingHideClick: Bool = false
    private var pendingClickLocation: CGPoint = .zero
    private var isHideAndSeekEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "HideAndSeekEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "HideAndSeekEnabled")
            return true
        }
        return UserDefaults.standard.bool(forKey: "HideAndSeekEnabled")
    }()
    private var debounceTimer: Timer?
    
    
    @objc func quitApp() {
        NSApplication.shared.terminate(self)
    }
    
    @objc func updateHideAndSeekState(_ notification: Notification) {
        if let enabled = notification.object as? Bool {
            isHideAndSeekEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: "HideAndSeekEnabled")
        }
    }
    
    @objc func dockChanged(notification: Notification) {
        updateDockItems()
    }
    
    @objc func updateDockItems() {
        if debounceTimer == nil {
            debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                self?.debounceTimer = nil
            }
        }
        performDockUpdate()
    }
    
    @objc func openPopupWindow() {
        openSettingsWindow()
        if let w = self.mainWindow {
            w.level = .floating
        }
    }
    
    @objc func systemWillSleep() {
        print("System going to sleep - disabling event tap")
        if let eventTap = self.eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
    }

    @objc func systemDidWake() {
        print("System woke up - re-enabling event tap")
        // Use a longer delay to ensure system is fully awake
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.recreateEventTapIfNeeded()
        }
    }


    func openSettingsWindow() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            let contentView = ContentView()
            let hostingController = NSHostingController(rootView: contentView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Version \(currentVersion)"
            window.styleMask = [.titled, .closable]
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.mainWindow = window
        }
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if !isAccessibilityEnabled() {
            promptForAccessibilityPermission()
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        NotificationCenter.default.addObserver(self, selector: #selector(updateHideAndSeekState(_:)), name: NSNotification.Name("HideAndSeekStateChanged"), object: nil)
        
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(dockChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(dockChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(dockChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(dockChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        
        // Add sleep/wake observers - SAFER APPROACH
        center.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        
        registerLoginItem()
        setupEventTap()
        print("Application did finish launching")
        updateDockItems()
    }

    
    func setupEventTap() {
        if let existingTap = self.eventTap {
            CGEvent.tapEnable(tap: existingTap, enable: false)
            CFMachPortInvalidate(existingTap)
            self.eventTap = nil
        }
        
        let eventMask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) |
                                    (1 << CGEventType.leftMouseUp.rawValue) |
                                    (1 << CGEventType.leftMouseDragged.rawValue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let eventTap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                    let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
                    return AppDelegate.eventTapCallback(proxy: proxy, type: type, event: event, appDelegate: appDelegate)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                print("Failed to create event tap")
                return
            }
            
            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            self.eventTap = eventTap
            print("Event tap created successfully")
        }
    }

    
    func getDockRects() -> Future<[DockItem]?, Never> {
        return Future { promise in
            DispatchQueue.global(qos: .userInitiated).async {
                var dockItems: [DockItem] = []
                
                let script = """
                tell application "System Events"
                    set dockItemList to {}
                    tell process "Dock"
                        set dockItems to every UI element of list 1
                        repeat with dockItem in dockItems
                            set dockPosition to position of dockItem
                            set dockSize to size of dockItem
                            set appID to name of dockItem
                            set end of dockItemList to {dockPosition, dockSize, appID}
                        end repeat
                        return dockItemList
                    end tell
                end tell
                """
                
                var error: NSDictionary?
                if let appleScript = NSAppleScript(source: script) {
                    let result = appleScript.executeAndReturnError(&error)
                    
                    if error != nil {
                        print("Error executing AppleScript: \(String(describing: error))")
                        promise(.success(nil))
                        return
                    }
                    
                    if result.descriptorType == typeAEList {
                        for index in 1...result.numberOfItems {
                            if let item = result.atIndex(index) {
                                if let positionDescriptor = item.atIndex(1),
                                   let sizeDescriptor = item.atIndex(2),
                                   let appIDDescriptor = item.atIndex(3) {
                                    
                                    let positionX = positionDescriptor.atIndex(1)?.doubleValue ?? 0
                                    let positionY = positionDescriptor.atIndex(2)?.doubleValue ?? 0
                                    let sizeWidth = sizeDescriptor.atIndex(1)?.doubleValue ?? 0
                                    let sizeHeight = sizeDescriptor.atIndex(2)?.doubleValue ?? 0
                                    let appID = appIDDescriptor.stringValue ?? "Unknown"
                                    
                                    let rect = NSRect(x: positionX, y: positionY, width: sizeWidth, height: sizeHeight)
                                    let dockItem = DockItem(rect: rect, appID: appID)
                                    dockItems.append(dockItem)
                                }
                            }
                        }
                    }
                }
                promise(.success(dockItems))
            }
        }
    }
    
    func registerLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            try SMAppService.mainApp.register()
        } catch {
            print("Error setting login item: \(error.localizedDescription)")
        }
    }
    
    func isAccessibilityEnabled() -> Bool {
        return AXIsProcessTrusted()
    }
    
    func promptForAccessibilityPermission() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
        Please enable accessibility permissions in System Preferences.
        Relaunch app after permission granted.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Preferences")
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            openAccessibilityPreferences()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
    
    func openAccessibilityPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
    
    func openAutomationPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        if let eventTap = self.eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    
    // New helper function to find running apps with enhanced logic
    private func findRunningApp(dockItemName: String, runningApps: [NSRunningApplication]) -> NSRunningApplication? {
        // First, try to find by exact localized name match
        if let app = runningApps.first(where: { $0.localizedName == dockItemName }) {
            return app
        }
        
        // Second, try to find by bundle identifier directly (in case dock item name matches bundle ID)
        if let app = runningApps.first(where: { $0.bundleIdentifier == dockItemName }) {
            return app
        }
        
        // Third, try partial matching on localized name (case insensitive)
        if let app = runningApps.first(where: {
            guard let localizedName = $0.localizedName else { return false }
            return localizedName.lowercased().contains(dockItemName.lowercased()) ||
                   dockItemName.lowercased().contains(localizedName.lowercased())
        }) {
            return app
        }
        
        return nil
    }
    
    private func isActiveAppFullscreen() -> Bool {
        let windows = NSApplication.shared.windows.filter { $0.isVisible && $0.isKeyWindow }
        for window in windows {
            if window.styleMask.contains(.fullSizeContentView) {
                return true
            }
        }
        return false
    }
    
    private func performDockUpdate() {
        getDockRects().sink { dockItems in
            self.dockItems = dockItems ?? []
        }.store(in: &cancellables)
        print("-- performDockUpdate --")
    }
    
    // Check if an app has minimized windows
    private func hasMinimizedWindows(_ app: NSRunningApplication) -> Bool {
        guard let appName = app.localizedName else { return false }
        
        let script = """
        tell application "System Events"
            tell application process "\(appName)"
                set minimizedWindows to (every window whose value of attribute "AXMinimized" is true)
                return count of minimizedWindows
            end tell
        end tell
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if error == nil {
                return result.int32Value > 0
            }
        }
        return false
    }

    // Check if Finder has any open windows
    private func finderHasOpenWindows() -> Bool {
        let script = """
        tell application "System Events"
            tell application process "Finder"
                set openWindows to (every window whose value of attribute "AXMinimized" is false)
                return count of openWindows
            end tell
        end tell
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if error == nil {
                return result.int32Value > 0
            }
        }
        return false
    }

    // Check if only Finder is running (excluding system processes)
    private func isOnlyFinderRunning() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        let userApps = runningApps.filter { app in
            app.activationPolicy == .regular &&
            app.localizedName != nil &&
            !app.isTerminated
        }
        
        return userApps.count == 1 && userApps.first?.localizedName == "Finder"
    }
    
    private func recreateEventTapIfNeeded() {
        // Check if current event tap is still valid
        if let eventTap = self.eventTap {
            // Try to re-enable existing tap first
            CGEvent.tapEnable(tap: eventTap, enable: true)
            
            // Test if the tap is working by checking if it's still valid
            if CFMachPortIsValid(eventTap) {
                print("Event tap re-enabled successfully")
                return
            } else {
                print("Event tap is invalid, creating new one")
                // Clean up invalid tap
                CFMachPortInvalidate(eventTap)
                self.eventTap = nil
            }
        }
        
        // Create new event tap if needed
        setupEventTap()
        updateDockItems()
    }
    
    // Check if the given app is the only foreground (visible) app
    private func isOnlyForegroundApp(app: NSRunningApplication) -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        let userApps = runningApps.filter {
            $0.activationPolicy == .regular &&
            $0.localizedName != nil &&
            !$0.isTerminated
        }
        let visibleApps = userApps.filter { !$0.isHidden }
        
        // Return true if this app is the only visible one
        return visibleApps.count == 1 && visibleApps.first?.processIdentifier == app.processIdentifier
    }

    
    static func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent?, appDelegate: AppDelegate) -> Unmanaged<CGEvent>? {
        guard let event = event else { return nil }
        
        if !appDelegate.isHideAndSeekEnabled || appDelegate.isActiveAppFullscreen() {
            return Unmanaged.passUnretained(event)
        }
        
        let mouseLocation = event.location
        
        // Handle mouse down
        if type == .leftMouseDown {
            appDelegate.mouseDownTime = CACurrentMediaTime()
            appDelegate.pendingHideClick = false
            appDelegate.pendingClickLocation = mouseLocation
            
            let runningApps = NSWorkspace.shared.runningApplications
            
            for dockItem in appDelegate.dockItems {
                if dockItem.rect.contains(mouseLocation) {
                    print("Mouse down on dock item: \(dockItem.appID)")
                    
                    if "Launchpad||Trash||Downloads".contains(dockItem.appID) {
                        return Unmanaged.passUnretained(event)
                    }
                    
                    if let app = appDelegate.findRunningApp(dockItemName: dockItem.appID, runningApps: runningApps) {
                        
                        // CRITICAL FIX: Check if app is currently active AND visible
                        // Only suppress event if we're going to hide an active, visible app
                        if app.isActive && !app.isHidden &&
                           !appDelegate.hasMinimizedWindows(app) &&
                           !(dockItem.appID == "Finder" && appDelegate.isOnlyFinderRunning()) &&
                           !(dockItem.appID == "Finder" && !appDelegate.finderHasOpenWindows() && !appDelegate.isOnlyFinderRunning()) &&
                           !appDelegate.isOnlyForegroundApp(app: app) {  // <-- Add this condition

                            
                            // App is active and visible - we will hide it
                            appDelegate.pendingHideClick = true
                            print("Will hide app: \(app.localizedName ?? "Unknown")")
                            return nil // Suppress mouse down only for hide operation
                        }
                        
                        // For all other cases (inactive, hidden, minimized windows),
                        // let the system handle the click normally to activate/restore the app
                        print("Letting system handle click for app: \(app.localizedName ?? "Unknown") (active: \(app.isActive), hidden: \(app.isHidden))")
                        return Unmanaged.passUnretained(event)
                    }
                    break
                }
            }
            
            return Unmanaged.passUnretained(event)
        }
        
        if type == .leftMouseDragged {
            // If a hide was pending, cancel it because the user is dragging.
            if appDelegate.pendingHideClick {
                print("Drag detected, cancelling pending hide click.")
                appDelegate.pendingHideClick = false
                // We don't need to suppress the original mouse down, as it was already suppressed.
                // The system will handle subsequent drag events.
            }
            return Unmanaged.passUnretained(event) // Pass the drag event to the system
        }
        
        // Handle mouse up
        let timeElapsed = CACurrentMediaTime() - appDelegate.mouseDownTime
        if type == .leftMouseUp {
            if appDelegate.pendingHideClick &&
               abs(mouseLocation.x - appDelegate.pendingClickLocation.x) < 10 &&
               abs(mouseLocation.y - appDelegate.pendingClickLocation.y) < 10 &&
               timeElapsed < appDelegate.clickThreshold {
                
                let runningApps = NSWorkspace.shared.runningApplications
                for dockItem in appDelegate.dockItems {
                    if dockItem.rect.contains(mouseLocation) {
                        if let app = appDelegate.findRunningApp(dockItemName: dockItem.appID, runningApps: runningApps) {
                            let success = app.hide()
                            print("App hidden \(success): \(app.localizedName ?? "Unknown")")
                        }
                        break
                    }
                }
                
                appDelegate.pendingHideClick = false
                return nil // Suppress mouse up for completed hide operation
            }
            
            appDelegate.pendingHideClick = false
            return Unmanaged.passUnretained(event)
        }
        
        return Unmanaged.passUnretained(event)
    }
}
