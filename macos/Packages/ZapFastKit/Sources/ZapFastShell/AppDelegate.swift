import AppKit
import FeatureConversation
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
        if DebugSnapshot.settingsPath != nil {
            DebugSnapshot.renderSettingsAndQuit(model: model)
            return
        }
        if DebugSnapshot.galleryPath != nil {
            DispatchQueue.main.async { DebugSnapshot.renderGalleryAndQuit() }
            return
        }
        if MediaEditorScript.steps != nil {
            for window in NSApp.windows { window.orderOut(nil) }
            MediaEditorScript.run(model: model)
            return
        }
        if DebugSnapshot.dumpsMenus {
            // After SwiftUI has built the menus from the scene's commands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { DebugSnapshot.dumpMenusAndQuit() }
            return
        }
        #endif
        let verbose = ProcessInfo.processInfo.environment["ZAPFAST_VERBOSE"] != nil
        model.bringToFront = {
            NSApp.activate()
            NSApp.windows.first(where: \.canBecomeMain)?.makeKeyAndOrderFront(nil)
        }
        model.start(verbose: verbose)
        // Copies handed to drags and to Contacts last time are done with.
        for leftover in ["ZapFast Drags", "ZapFast Contacts"] {
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appending(path: leftover))
        }
        observeBadge()
        watchInput()
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

    /// Closing the window keeps ZapFast linked unless that is turned off.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.preferences.keepRunning
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    /// Input in any of the app's windows keeps the app lock's idle time
    /// from running out.
    private func watchInput() {
        let events: NSEvent.EventTypeMask = [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel, .leftMouseDragged, .mouseMoved,
        ]
        NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.model.appLock.noteInput()
            return event
        }
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
