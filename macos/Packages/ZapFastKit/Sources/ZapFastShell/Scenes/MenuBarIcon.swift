import AppKit
import Observation
import SwiftUI
import ZapFastCore

/// The menu bar icon and its menu, as upstream's tray: open, lock, quit;
/// never a chat's name or a count, so nothing shows while locked.
///
/// An AppKit status item rather than SwiftUI's `MenuBarExtra`: that one was
/// rebuilt, and its menu bar snapshots redrawn, with nearly every update
/// anywhere in the app, close to a tenth of the main thread while scrolling
/// a chat. This one changes only when what it shows does.
@MainActor
final class MenuBarIcon: NSObject, NSMenuDelegate {
    private let model: AppModel
    private var item: NSStatusItem?
    private var shown: (visible: Bool, unread: Bool)?
    /// Brings the main window forward, made again if it was closed.
    var openMainWindow: () -> Void = {}

    init(model: AppModel) {
        self.model = model
        super.init()
        observe()
    }

    private func observe() {
        let state = withObservationTracking {
            (visible: model.preferences.menuBarIcon,
             unread: model.chats.unreadChatCount > 0 && !model.appLock.isLocked)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observe() }
        }
        guard shown.map({ $0 != state }) ?? true else { return }
        shown = state
        apply(state)
    }

    private func apply(_ state: (visible: Bool, unread: Bool)) {
        guard state.visible else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let item = item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if self.item == nil {
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        }
        let image = NSImage(
            systemSymbolName: state.unread ? "message.badge.filled.fill" : "message",
            accessibilityDescription: "ZapFast"
        )
        image?.isTemplate = true
        item.button?.image = image
    }

    /// Built as it opens, so the lock item reflects the lock right then.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: String(localized: "Open ZapFast"), action: #selector(open), keyEquivalent: "").target = self
        if model.appLock.isEnabled {
            let lock = menu.addItem(withTitle: String(localized: "Lock ZapFast"), action: #selector(lock), keyEquivalent: "")
            lock.target = self
            lock.isEnabled = !model.appLock.isLocked
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit ZapFast"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func open() {
        NSApp.activate()
        openMainWindow()
    }

    @objc private func lock() {
        model.appLock.lock()
    }
}
