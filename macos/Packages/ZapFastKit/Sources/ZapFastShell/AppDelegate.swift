import AppKit
import Observation
import ZapFastCore

/// App lifecycle: starts the backend, reports whether the person is looking,
/// keeps the Dock badge current, and shuts down cleanly on quit.
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public let model = AppModel()

    override public init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if DebugSnapshot.galleryPath != nil {
            DispatchQueue.main.async { DebugSnapshot.renderGalleryAndQuit() }
            return
        }
        #endif
        let verbose = ProcessInfo.processInfo.environment["ZAPFAST_VERBOSE"] != nil
        model.bringToFront = {
            NSApp.activate()
            NSApp.windows.first(where: \.canBecomeMain)?.makeKeyAndOrderFront(nil)
        }
        model.start(verbose: verbose)
        observeBadge()
        #if DEBUG
        DebugSnapshot.scheduleIfRequested(model: model)
        #endif
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        model.setActive(true)
    }

    public func applicationDidResignActive(_ notification: Notification) {
        model.setActive(false)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    /// Unread chats on the Dock icon, re-evaluated whenever they change.
    private func observeBadge() {
        withObservationTracking {
            let count = model.chats.unreadChatCount
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeBadge() }
        }
    }
}
