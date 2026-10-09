import AppKit
import FeatureCalls
import FeatureConversation
import Observation
import ZapFastCore
import ZapFastDesign

/// App lifecycle: starts the backend, reports whether the person is looking,
/// keeps the Dock badge current, and shuts down cleanly on quit.
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public let model: AppModel
    private var menuBarIcon: MenuBarIcon?
    private var mainWindow: MainWindowController?
    private var chatWindows: [ChatWindowController] = []
    private var callWindow: CallWindowController?

    override public init() {
        model = TimelineBenchmark.isRequested
            ? TimelineBenchmark.makeModel()
            : AppModel(accountID: LiveAccounts.activeAccount(paths: .standard()))
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Avatars decode before any timeline is open to say which display.
        if let space = NSScreen.main?.colorSpace?.cgColorSpace { DisplayImage.colorSpace = space }
        if !Self.drawsSnapshotOnly {
            let window = MainWindowController(model: model)
            mainWindow = window
            window.show()
        }
        if TimelineBenchmark.isRequested {
            TimelineBenchmark.start(model: model)
            return
        }
        #if DEBUG
        if DebugSnapshot.settingsPath != nil {
            DebugSnapshot.renderSettingsAndQuit(model: model)
            return
        }
        if DebugSnapshot.galleryPath != nil {
            DispatchQueue.main.async { DebugSnapshot.renderGalleryAndQuit() }
            return
        }
        if DebugSnapshot.timelinePath != nil {
            DispatchQueue.main.async { DebugSnapshot.renderTimelineAndQuit() }
            return
        }
        if DebugSnapshot.sidebarPath != nil {
            DispatchQueue.main.async { DebugSnapshot.renderSidebarAndQuit() }
            return
        }
        if DebugSnapshot.lottiePath != nil {
            DispatchQueue.main.async { DebugSnapshot.renderLottieAndQuit() }
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
        model.bringToFront = { [weak self] in
            NSApp.activate()
            self?.mainWindow?.show()
        }
        model.openChatWindow = { [weak self] chat in self?.openChatWindow(chat) }
        callWindow = CallWindowController(model: model)
        model.start(verbose: verbose)
        HangMonitor.start()
        // Copies handed to drags and to Contacts last time are done with.
        for leftover in ["ZapFast Drags", "ZapFast Contacts"] {
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appending(path: leftover))
        }
        observeBadge()
        watchInput()
        let icon = MenuBarIcon(model: model)
        icon.openMainWindow = { [weak self] in self?.mainWindow?.show() }
        menuBarIcon = icon
        if let rounds = LiveStress.rounds { LiveStress.start(model: model, rounds: rounds) }
        #if DEBUG
        DebugSnapshot.scheduleIfRequested(model: model)
        DebugCommands.start(model: model)
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

    /// The Dock icon brings the main window back once it was closed.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { mainWindow?.show() }
        return true
    }

    /// The debug snapshots draw their own windows and quit; they need no
    /// main window.
    private static var drawsSnapshotOnly: Bool {
        #if DEBUG
        DebugSnapshot.settingsPath != nil || DebugSnapshot.galleryPath != nil || DebugSnapshot.timelinePath != nil
            || DebugSnapshot.sidebarPath != nil || DebugSnapshot.lottiePath != nil || MediaEditorScript.steps != nil || DebugSnapshot.dumpsMenus
        #else
        false
        #endif
    }

    /// Links from the Share extension (`zapfast-mac://share`).
    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { model.receiveShare(url) }
    }

    /// A chat in a window of its own; one already open comes forward.
    private func openChatWindow(_ chat: String) {
        if let open = chatWindows.first(where: { $0.chatID == chat }) {
            open.show()
            return
        }
        let window = ChatWindowController(chatID: chat, model: model)
        window.onClose = { [weak self, weak window] in
            self?.chatWindows.removeAll { $0 === window }
        }
        chatWindows.append(window)
        window.show()
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
