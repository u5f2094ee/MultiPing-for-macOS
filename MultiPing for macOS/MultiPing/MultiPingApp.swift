import SwiftUI

// AppDelegate to handle application lifecycle events AND window events
@MainActor class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate { // Added NSWindowDelegate
    static weak var pingManagerInstance: PingManager?
    private var windowObservation: NSKeyValueObservation? // KVO handle for new windows

    override init() {
        super.init()
        // Set up KVO for new windows as early as possible.
        windowObservation = NSApp.observe(\.windows, options: [.initial, .new]) { [weak self] app, change in
            // .initial ensures this runs for windows existing at the time of observation.
            // .new ensures it runs for newly added windows.
            print("AppDelegate: KVO detected change in application windows.")
            Task { @MainActor in
                self?.assignDelegateToAllWindows()
            }
        }
    }
    
    // This method is called after the application has finished launching and has processed its initial events.
    // This is a good place to ensure delegates are set for any windows that might have been created
    // by the time this method is called, though KVO with .initial should cover it.
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("AppDelegate: applicationDidFinishLaunching.")
        // KVO with .initial should have already called assignDelegateToAllWindows.
        // Calling it again here is a safeguard.
        assignDelegateToAllWindows()
    }

    // Helper method to assign this AppDelegate instance as the delegate
    // to relevant application windows.
    func assignDelegateToAllWindows() {
        DispatchQueue.main.async { // Ensure UI updates (like setting a delegate) are on the main thread
            for window in NSApp.windows {
                // We are interested in the main "Targets Collector" window and "Ping Results" windows.
                let isRelevantWindowType = self.isRelevantWindow(window)
                
                // Only assign if it's a relevant window and the delegate is not already this instance.
                if isRelevantWindowType && !(window.delegate is AppDelegate) {
                    print("AppDelegate: Assigning self as delegate to window: '\(window.title)' (ID: \(window.identifier?.rawValue ?? "N/A"))")
                    window.delegate = self
                }
            }
        }
    }

    // Called just before the application terminates.
    // This is our main cleanup point.
    func applicationWillTerminate(_ notification: Notification) {
        print("AppDelegate: Application will terminate. Performing final cleanup.")
        if let manager = AppDelegate.pingManagerInstance {
            print("AppDelegate: Found PingManager instance (\(ObjectIdentifier(manager))). Preparing synchronous shutdown.")
            manager.prepareForAppTermination(clearResults: true)
            print("AppDelegate: synchronous shutdown finished.")
        } else {
            print("AppDelegate: PingManager instance not found for final cleanup in applicationWillTerminate.")
        }
        windowObservation?.invalidate()
        windowObservation = nil
        print("AppDelegate: applicationWillTerminate finished.")
    }

    // This delegate method is called when the user clicks the red close button on a window.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        print("AppDelegate: windowShouldClose called for window: '\(sender.title)'")

        // Determine if this is the last "relevant" window.
        // Relevant windows are our main IP input window and any results windows.
        // We count only visible windows that are of the types we manage.
        let relevantWindows = NSApp.windows.filter { window in
            return isRelevantWindow(window) && window.isVisible // Consider only visible windows
        }
        
        print("AppDelegate: Number of relevant visible windows: \(relevantWindows.count)")
        if relevantWindows.count == 1 && relevantWindows.first == sender {
            print("AppDelegate: This is the last relevant window ('\(sender.title)'). Preparing ping shutdown before normal close.")
            AppDelegate.pingManagerInstance?.prepareForAppTermination(clearResults: true)
            return true
        } else {
            print("AppDelegate: Window '\(sender.title)' is not the last relevant window, or other relevant windows exist. Allowing this window to close normally.")
            // This allows individual results windows to close if the main input window (or other results windows) are still open.
            // The .onDisappear of the view within that window should handle its specific cleanup.
            return true // Allow this specific window to close.
        }
    }
    
    // This method is called if all windows are closed AND windowShouldClose allowed the last window to close,
    // OR if termination happens for other reasons where this check is made.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        print("AppDelegate: applicationShouldTerminateAfterLastWindowClosed called.")
        // If windowShouldClose handled the last window by calling NSApp.terminate,
        // this method might not be the primary decider for that specific path.
        // However, if the last window was allowed to close normally by windowShouldClose
        // (which shouldn't happen if it's the *actual* last relevant one per our logic),
        // then the app should terminate.
        // Generally, if we reach here, it means the app should terminate.
        return true
    }

    private func isRelevantWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "ip-input" ||
        window.identifier?.rawValue == "ping-results" ||
        window.title.starts(with: "Ping Results")
    }

    deinit {
        windowObservation?.invalidate() // Ensure KVO is cleaned up
    }
}

@main
struct MultiPingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var manager = PingManager()

    var body: some Scene {
        Window("Targets Collector", id: "ip-input") { // ID "ip-input" is used by AppDelegate
            IPInputView(manager: manager)
                .onAppear {
                    print("MultiPingApp: IPInputView appeared, assigning PingManager (\(ObjectIdentifier(manager))) to AppDelegate.")
                    AppDelegate.pingManagerInstance = manager
                    // AppDelegate's KVO with .initial should handle setting the window delegate for this initial window.
                }
        }
    }
}
