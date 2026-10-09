import AppKit
import FeatureChats
import FeatureConversation
import Observation
import SwiftUI
import ZapFastCore
import ZapFastSharedUI

/// The main window, in AppKit: the sidebar, the open chat and its search
/// in a split view, one toolbar for all three, and in their place the lock
/// screen or linking.
///
/// It was SwiftUI's `Window` with a `NavigationSplitView`. Every change of
/// the window's size went through SwiftUI's layout of the whole window, its
/// toolbar and every island in it, which made resizing cost about twice
/// the timeline's own work; here SwiftUI lays out only the islands whose
/// own size changes.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private var model: AppModel
    private var root = RootViewController()
    private lazy var split = MainSplitViewController(model: model)
    private lazy var toolbar = makeToolbar()
    private var observed = 0
    private var mode: RootViewController.Mode?
    private var appeared = false

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "ZapFast"
        // The chat's name is in its header; the title names the window
        // in the Window menu and the Dock only.
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // Narrower than the list and a chat side by side, one of them shows.
        window.contentMinSize = NSSize(width: 360, height: 480)
        super.init(window: window)
        window.delegate = self
        root.model = model
        window.contentViewController = root
        window.setContentSize(NSSize(width: 1100, height: 740))
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private static let frameName = "ZapFastMainWindow"

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "ZapFastMain")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    /// Shows another account in the same window, where it was: its own
    /// chats, toolbar, lock or linking screen.
    func show(model next: AppModel) {
        guard next !== model else { return show() }
        let frame = window?.frame
        model = next
        let root = RootViewController()
        root.model = next
        self.root = root
        split = MainSplitViewController(model: next)
        toolbar = makeToolbar()
        window?.toolbar = nil
        window?.contentViewController = root
        if let frame { window?.setFrame(frame, display: true) }
        mode = nil
        observe()
        show()
    }

    /// Brings the window forward, made again if it was closed.
    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if !appeared {
            appeared = true
            model.mainWindowAppeared()
        }
    }

    // MARK: What the window shows

    private func observe() {
        observed += 1
        let round = observed
        let model = model
        let state = withObservationTracking {
            (locked: model.appLock.isLocked, linked: model.isLinked)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.observed == round else { return }
                    self.observe()
                }
            }
        }
        let mode: RootViewController.Mode = state.locked ? .locked : state.linked ? .chats : .linking
        guard mode != self.mode else { return }
        self.mode = mode
        if mode == .chats {
            root.show(.chats, chats: split)
            if window?.toolbar == nil { window?.toolbar = toolbar }
            split.detail.onChange = { [weak self] in self?.chatChanged() }
            split.onArranged = { [weak self] in self?.arranged() }
            chatChanged()
            arranged()
        } else {
            root.show(mode, chats: nil)
            window?.toolbar = nil
            window?.title = "ZapFast"
        }
    }

    /// In a narrow window the open chat has a way back to the list.
    private func arranged() {
        let alone = split.showsChatAlone
        chatsBack?.isHidden = !alone
        split.sidebar.itemsHidden = alone
        // The collapsed sidebar has no room for its toggle, nor the chat
        // alone a use for it; the View menu has it.
        window?.toolbar?.items.first { $0.itemIdentifier == .toggleSidebar }?.isHidden = split.isCompact || split.isNarrow
        // The space that pushes the sidebar's buttons to its edge would
        // push the chat's name out of a narrow toolbar.
        window?.toolbar?.items.first { $0.itemIdentifier == .flexibleSpace }?.isHidden = alone || split.isCompact
        // The chat alone has no sidebar edge to follow: the separator would
        // keep the old sidebar's room at the toolbar's start. The list alone
        // keeps it, or its buttons would go with the hidden chat's section.
        if let toolbar = window?.toolbar {
            let index = toolbar.items.firstIndex { $0.itemIdentifier == .sidebarTrackingSeparator }
            if alone, let index {
                toolbar.removeItem(at: index)
            } else if !alone, index == nil,
                      let toggle = toolbar.items.firstIndex(where: { $0.itemIdentifier == .toggleSidebar }) {
                toolbar.insertItem(withItemIdentifier: .sidebarTrackingSeparator, at: toggle + 1)
            }
        }
    }

    private var chatsBack: NSToolbarItem?
    static let chatsBackItem = NSToolbarItem.Identifier("ZapFastChatsBack")

    @objc private func backToChats() {
        model.selectedChatID = nil
    }

    /// The window is named after the open chat, and the inspector shows
    /// while its search is open. Nothing names a chat while locked.
    private func chatChanged() {
        guard mode == .chats else { return }
        window?.title = split.detail.chatTitle ?? "ZapFast"
        split.showInspector(split.detail.searchShown)
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        // Closing the window locks the Locked folder again, as upstream's does.
        model.closeLockedChats()
    }

    // MARK: Toolbar

    /// As SwiftUI laid them out: the account switcher first, the sidebar's
    /// buttons at its trailing edge, then the chat's header, and its search
    /// and menu at the far end.
    private static let items: [NSToolbarItem.Identifier] = [
        SidebarViewController.accountsItem,
        .flexibleSpace,
        SidebarViewController.backItem,
        SidebarViewController.filterItem,
        SidebarViewController.newChatItem,
        .toggleSidebar,
        .sidebarTrackingSeparator,
        MainWindowController.chatsBackItem,
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
        if identifier == Self.chatsBackItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: nil)
            item.label = String(localized: "Chats")
            item.toolTip = String(localized: "Back to the chats")
            item.isBordered = true
            item.target = self
            item.action = #selector(backToChats)
            // The way back stays when a narrow toolbar hides the rest.
            item.visibilityPriority = .user
            item.isHidden = !split.showsChatAlone
            chatsBack = item
            return item
        }
        return split.sidebar.toolbarItem(identifier) ?? split.detail.toolbarItem(identifier)
    }
}

/// The sidebar, the chat and the chat's search.
///
/// Narrower than `narrowWidth`, as upstream's narrow window, one of the list
/// and the chat shows: the list until a chat opens, then the chat with a way
/// back. The sidebar can also collapse to the chats' pictures.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    let sidebar: SidebarViewController
    let detail: ChatDetailViewController
    private let model: AppModel
    private let sidebarItem: NSSplitViewItem
    private let detailItem: NSSplitViewItem
    private let inspectorItem: NSSplitViewItem
    private var placedSidebar = false
    private var narrow = false
    /// The sidebar as the person left it before the window narrowed.
    private var sidebarWasCollapsed = false
    /// The sidebar's width before it collapsed to the pictures.
    private var fullSidebarWidth: CGFloat = 320
    private var compactShown = false
    private var observed = 0
    var onArranged: () -> Void = {}

    static let narrowWidth: CGFloat = 620
    static let compactWidth: CGFloat = 76

    /// The sidebar shows only the chats' pictures.
    var isCompact: Bool { compactShown }
    var isNarrow: Bool { narrow }

    /// A narrow window shows the open chat on its own.
    var showsChatAlone: Bool { narrow && model.selectedChatID != nil }

    init(model: AppModel) {
        self.model = model
        sidebar = SidebarViewController(model: model)
        detail = ChatDetailViewController(model: model, source: .selected)
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        inspectorItem = NSSplitViewItem(inspectorWithViewController: detail.inspectorController)
        detailItem = NSSplitViewItem(viewController: detail)
        super.init(nibName: nil, bundle: nil)
        sidebarItem.minimumThickness = 260
        sidebarItem.maximumThickness = 460
        sidebarItem.canCollapse = true
        detailItem.canCollapse = true
        if #available(macOS 26, *) {
            // The chat's wallpaper reaches under the floating sidebar.
            detailItem.automaticallyAdjustsSafeAreaInsets = true
        }
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 420
        inspectorItem.isCollapsed = true
        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
        addSplitViewItem(inspectorItem)
        sidebar.install(in: sidebarItem)
        observeArrangement()
    }

    /// A chat opening or closing, and the collapsed sidebar's setting,
    /// change what shows.
    private func observeArrangement() {
        observed += 1
        let round = observed
        _ = withObservationTracking {
            (model.selectedChatID, model.preferences.compactSidebar)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.observed == round else { return }
                    self.observeArrangement()
                }
            }
        }
        arrange()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let now = view.bounds.width < Self.narrowWidth
        // The list alone fills the window as it grows or shrinks.
        if now, narrow, detailItem.isCollapsed, abs(sidebar.view.frame.width - view.bounds.width) > 1 {
            DispatchQueue.main.async { [weak self] in self?.fillWithList() }
        }
        guard now != narrow else { return }
        if now { sidebarWasCollapsed = sidebarItem.isCollapsed }
        narrow = now
        DispatchQueue.main.async { [weak self] in self?.arrange() }
    }

    private func fillWithList() {
        guard narrow, detailItem.isCollapsed else { return }
        splitView.setPosition(view.bounds.width, ofDividerAt: 0)
    }

    private func arrange() {
        let compact = model.preferences.compactSidebar && !narrow
        sidebar.setCompact(compact)
        if narrow {
            let chatOpen = model.selectedChatID != nil
            sidebarItem.minimumThickness = 260
            sidebarItem.maximumThickness = chatOpen ? 460 : NSSplitViewItem.unspecifiedDimension
            detailItem.isCollapsed = !chatOpen
            sidebarItem.isCollapsed = chatOpen
            if !chatOpen { fillWithList() }
        } else {
            if compact, !compactShown, !sidebarItem.isCollapsed { fullSidebarWidth = sidebar.view.frame.width }
            sidebarItem.minimumThickness = compact ? Self.compactWidth : 260
            sidebarItem.maximumThickness = compact ? Self.compactWidth : 460
            detailItem.isCollapsed = false
            if sidebarItem.isCollapsed != sidebarWasCollapsed { sidebarItem.isCollapsed = sidebarWasCollapsed }
            if compact != compactShown, !sidebarItem.isCollapsed {
                splitView.setPosition(compact ? Self.compactWidth : fullSidebarWidth, ofDividerAt: 0)
            }
        }
        compactShown = compact && !narrow
        // The chat's own layout follows its new width now, not on the next resize.
        detail.view.needsLayout = true
        onArranged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.autosaveName = Self.autosaveName
    }

    private static let autosaveName = "ZapFastMainSplit"

    override func viewDidAppear() {
        super.viewDidAppear()
        // 320 points the first time; after that, as the person left it.
        guard !placedSidebar else { return }
        placedSidebar = true
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(Self.autosaveName)") == nil {
            splitView.setPosition(320, ofDividerAt: 0)
        }
    }

    func showInspector(_ shown: Bool) {
        guard inspectorItem.isCollapsed == shown else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || view.window == nil {
            inspectorItem.isCollapsed = !shown
        } else {
            inspectorItem.animator().isCollapsed = !shown
        }
    }
}

/// Holds what the window shows: the chats, the lock screen or linking;
/// over them the notices, and the window's own sheets.
@MainActor
final class RootViewController: NSViewController {
    enum Mode { case chats, locked, linking }

    var model: AppModel!
    private var content: NSViewController?
    private let screen = NSHostingController(rootView: AnyView(EmptyView()))
    private let notices = NSHostingController(rootView: AnyView(EmptyView()))
    private var observed = 0
    private let presenters = PassiveHostingView(rootView: AnyView(EmptyView()))

    override func loadView() {
        let view = RootView(frame: NSRect(x: 0, y: 0, width: 1100, height: 740))
        view.onLayout = { [weak self] in self?.place() }
        screen.sizingOptions = []
        notices.sizingOptions = []
        presenters.sizingOptions = []
        view.addSubview(presenters)
        addChild(notices)
        view.addSubview(notices.view)
        self.view = view
        notices.rootView = AnyView(RootNotices(model: model))
        presenters.rootView = AnyView(RootPresenters(model: model))
        observeNotices()
    }

    /// The notices' island is as large as they are, so it takes clicks
    /// only on them.
    private func observeNotices() {
        observed += 1
        let round = observed
        _ = withObservationTracking {
            model.notices.count
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.observed == round else { return }
                    self.observeNotices()
                    // After the notice's own animation has its size.
                    self.view.needsLayout = true
                }
            }
        }
        view.needsLayout = true
    }

    func show(_ mode: Mode, chats: NSViewController?) {
        let next: NSViewController
        switch mode {
        case .chats:
            next = chats ?? screen
        case .locked, .linking:
            screen.rootView = AnyView(RootScreen(model: model, locked: mode == .locked))
            next = screen
        }
        guard next !== content else { return }
        if let content {
            content.view.removeFromSuperview()
            content.removeFromParent()
        }
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.width, .height]
        view.addSubview(next.view, positioned: .below, relativeTo: presenters)
        content = next
    }

    private func place() {
        let bounds = view.bounds
        let width = min(bounds.width, 460)
        let height = model.notices.isEmpty ? 0 : notices.sizeThatFits(in: CGSize(width: width, height: bounds.height)).height
        notices.view.frame = CGRect(
            x: ((bounds.width - width) / 2).rounded(), y: view.safeAreaInsets.top + 8,
            width: width, height: height
        )
        presenters.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    }
}

private final class RootView: NSView {
    var onLayout: () -> Void = {}

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout()
    }
}
