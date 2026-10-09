import AppKit
import FeatureConversation
import Observation
import SwiftUI
import ZapFastCore
import ZapFastSharedUI

/// One chat in a window of its own, from its menu. It shows nothing while
/// the app lock is closed, a locked chat only while Locked Chats is open,
/// and a note once the chat is gone.
@MainActor
final class ChatWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let chatID: String
    let model: AppModel
    private let detail: ChatDetailViewController
    private let split = NSSplitViewController()
    private let inspectorItem: NSSplitViewItem
    private let note = NSHostingController(rootView: AnyView(EmptyView()))
    private let container = NSViewController()
    private var observed = 0
    private var available: Bool?
    /// Told when the window has closed, to be let go.
    var onClose: () -> Void = {}

    init(chatID: String, model: AppModel) {
        self.chatID = chatID
        self.model = model
        detail = ChatDetailViewController(model: model, source: .chat(chatID))
        inspectorItem = NSSplitViewItem(inspectorWithViewController: detail.inspectorController)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("chat")
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 380, height: 420)
        super.init(window: window)
        window.delegate = self
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 420
        inspectorItem.isCollapsed = true
        split.addSplitViewItem(inspectorItem)
        note.sizingOptions = []
        container.view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 680))
        window.contentViewController = container
        window.setContentSize(NSSize(width: 520, height: 680))
        window.center()
        detail.onChange = { [weak self] in self?.chatChanged() }
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func observe() {
        observed += 1
        let round = observed
        let model = model
        let chatID = chatID
        let state = withObservationTracking {
            (
                locked: model.appLock.isLocked,
                available: model.chats.chat(chatID).map { !$0.locked || model.lockedChats.isOpen } ?? false
            )
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.observed == round else { return }
                    self.observe()
                }
            }
        }
        let shows = !state.locked && state.available
        guard shows != available else {
            if !shows { showNote(locked: state.locked) }
            return
        }
        let first = available == nil
        available = shows
        if shows {
            place(split)
            window?.toolbar = makeToolbar()
            model.chatWindowAppeared(chatID)
            chatChanged()
        } else {
            showNote(locked: state.locked)
            place(note)
            window?.toolbar = nil
            window?.title = "ZapFast"
            if !first { model.chatWindowDisappeared(chatID) }
        }
    }

    private func showNote(locked: Bool) {
        note.rootView = locked
            ? AnyView(ContentUnavailableView(
                "ZapFast Is Locked",
                systemImage: "lock.fill",
                description: Text("Unlock ZapFast in its main window.")
            ))
            : AnyView(ContentUnavailableView("This chat is not available", systemImage: "bubble.left.and.exclamationmark.bubble.right"))
    }

    private func place(_ content: NSViewController) {
        for child in container.children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        container.addChild(content)
        content.view.frame = container.view.bounds
        content.view.autoresizingMask = [.width, .height]
        container.view.addSubview(content.view)
    }

    private func chatChanged() {
        guard available == true else { return }
        window?.title = detail.chatTitle ?? "ZapFast"
        let shown = detail.searchShown
        guard inspectorItem.isCollapsed == shown else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            inspectorItem.isCollapsed = !shown
        } else {
            inspectorItem.animator().isCollapsed = !shown
        }
    }

    func windowWillClose(_ notification: Notification) {
        observed += 1
        if available == true { model.chatWindowDisappeared(chatID) }
        available = nil
        onClose()
    }

    // MARK: Toolbar

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "ZapFastChat")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    private static let items: [NSToolbarItem.Identifier] = [
        ChatDetailViewController.headerItem,
        .flexibleSpace,
        ChatDetailViewController.videoCallItem,
        ChatDetailViewController.callItem,
        ChatDetailViewController.searchItem,
        ChatDetailViewController.actionsItem,
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.items
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.items
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        detail.toolbarItem(identifier)
    }
}
