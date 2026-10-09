import AppKit
import Observation
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// What the sidebar shows: the search, the filter or label, Archived.
@Observable
final class SidebarState {
    var query = ""
    var filter: ChatFilter = .all
    /// A label chosen in place of a built-in filter.
    var label: String?
    var showingArchived = false
    /// The chat the arrow keys reached in the search results: marked, not
    /// opened, until Return.
    var cursor: String?
}

/// The sidebar, in AppKit: a search field, the chats in their table (the
/// Locked Chats and Archived folders above them), and while a search finds
/// messages, SwiftUI's list of chats and messages in its place. The filter,
/// New Chat and Back are items for the window's toolbar.
///
/// SwiftUI draws only the rows, the notes over an empty list, the sync
/// status and the sheets, each its own island.
public final class SidebarViewController: NSViewController, NSSearchFieldDelegate, NSMenuDelegate {
    public static let filterItem = NSToolbarItem.Identifier("ZapFastSidebarFilter")
    public static let newChatItem = NSToolbarItem.Identifier("ZapFastSidebarNewChat")
    public static let backItem = NSToolbarItem.Identifier("ZapFastSidebarBack")
    public static let accountsItem = NSToolbarItem.Identifier("ZapFastSidebarAccounts")

    public let model: AppModel
    private let state = SidebarState()
    private let table = ChatTableController()
    private lazy var tableScroll = table.makeScrollView()
    private let searchField = NSSearchField()
    private let searchBar = NSView()
    private let results = NSHostingView(rootView: AnyView(EmptyView()))
    private let empty = PassiveHostingView(rootView: AnyView(EmptyView()))
    private let sync = NSHostingView(rootView: AnyView(EmptyView()))
    private let presenters = PassiveHostingView(rootView: AnyView(EmptyView()))
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private lazy var accountsMenu = model.hub.map { AccountsMenu(hub: $0) }
    private var accountsObserved = 0
    private var observed = 0
    private var searchRequests = 0
    private var wasLocked = false
    /// The chats the list shows, in order, for the arrow keys to walk.
    private var shownIDs: [String] = []
    /// The cursor the table was last scrolled to.
    private var revealedCursor: String?
    /// The open chat as last seen: opening another, from the results or
    /// anywhere, puts the cursor away.
    private var lastSelection: String?
    /// The search bar and the sync status sit in the split view item's
    /// accessories on macOS 26, which inset the list themselves.
    private var usesAccessories = false
    /// The sync status's accessory, shown while syncing or offline.
    private var syncAccessory: NSViewController?

    public init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override public func loadView() {
        let view = SidebarView()
        view.onLayout = { [weak self] in self?.place() }
        searchField.placeholderString = String(localized: "Search")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .large
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: Self.searchInset),
            searchField.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -Self.searchInset),
            searchField.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            searchBar.heightAnchor.constraint(equalToConstant: Self.searchBarHeight),
        ])
        results.sizingOptions = []
        empty.sizingOptions = []
        sync.sizingOptions = [.intrinsicContentSize]
        presenters.sizingOptions = []
        for island in [tableScroll, results, empty, presenters] as [NSView] {
            view.addSubview(island)
        }
        sync.rootView = AnyView(SyncStatus(session: model.session))
        presenters.rootView = AnyView(SidebarPresenters(model: model))
        self.view = view
        searchRequests = model.sidebarSearchRequests
        observe()
    }

    /// On macOS 26 the search bar and the sync status go in the item's
    /// accessories, under the toolbar and at the foot of the sidebar.
    public func install(in item: NSSplitViewItem) {
        if #available(macOS 26, *) {
            usesAccessories = true
            let top = NSSplitViewItemAccessoryViewController()
            top.view = searchBar
            item.addTopAlignedAccessoryViewController(top)
            let bottom = NSSplitViewItemAccessoryViewController()
            bottom.view = sync
            bottom.isHidden = sync.isHidden
            item.addBottomAlignedAccessoryViewController(bottom)
            syncAccessory = bottom
        } else {
            view.addSubview(searchBar)
            view.addSubview(sync)
        }
        view.needsLayout = true
    }

    // MARK: Following the chats

    private func observe() {
        observed += 1
        let round = observed
        let model = model
        let state = state
        let shown = withObservationTracking {
            let inLocked = model.lockedChats.isOpen
            let chats = inLocked
                ? model.chats.lockedChats(query: state.query)
                : model.chats.visibleChats(
                    filter: state.filter, query: state.query, archived: state.showingArchived,
                    label: state.label, kept: model.keptUnread
                )
            let trimmed = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
            let hits = inLocked || trimmed.isEmpty || model.search.messageQuery != trimmed ? [] : model.search.messageHits
            return (
                chats: chats,
                shortcutTitles: chats.prefix(9).map { model.chats.title(for: $0) },
                hits: hits,
                rows: Self.rows(chats, model: model, state: state, inLocked: inLocked),
                selection: model.selectedChatID,
                cursor: state.cursor,
                inLocked: inLocked,
                labels: model.chats.labels.map(\.id),
                searchRequests: model.sidebarSearchRequests,
                syncing: model.session.isSyncing || model.session.link.isDisconnected
            )
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.observed == round else { return }
                    self.observe()
                }
            }
        }
        // Leaving or opening Locked Chats starts a new search.
        if shown.inLocked != wasLocked {
            wasLocked = shown.inLocked
            setQuery("")
        }
        // A deleted label stops filtering.
        if let label = state.label, !shown.labels.contains(label) { state.label = nil }
        let ids = shown.chats.map(\.id)
        shownIDs = ids
        if shown.selection != lastSelection {
            lastSelection = shown.selection
            state.cursor = nil
        }
        // Results that changed under the cursor leave it nowhere.
        if let cursor = state.cursor, !ids.contains(cursor) { state.cursor = nil }
        let cursor = state.cursor
        if model.sidebarOrder != ids { model.sidebarOrder = ids }
        if model.sidebarShortcutTitles != shown.shortcutTitles { model.sidebarShortcutTitles = shown.shortcutTitles }
        model.sidebarKeepsUnread = state.filter == .unread && state.label == nil && state.query.isEmpty
            && !state.showingArchived && !shown.inLocked
        table.update(rows: shown.rows, selection: cursor ?? shown.selection, model: model) { [model, state] id in
            if let id { model.keepUnread(id) }
            state.cursor = nil
            model.selectedChatID = id
        }
        if cursor != revealedCursor {
            revealedCursor = cursor
            if let cursor { table.reveal(cursor) }
        }
        let searching = !shown.hits.isEmpty
        tableScroll.isHidden = searching
        results.isHidden = !searching
        results.rootView = searching
            ? AnyView(SidebarSearchList(chats: shown.chats, hits: shown.hits, query: state.query, cursor: cursor, model: model))
            : AnyView(EmptyView())
        let nothing = shown.chats.isEmpty && shown.hits.isEmpty
        empty.isHidden = !nothing
        empty.rootView = nothing
            ? AnyView(EmptyState(
                query: state.query, filter: state.filter, archived: state.showingArchived,
                locked: shown.inLocked, labeled: state.label != nil
            ))
            : AnyView(EmptyView())
        sync.isHidden = !shown.syncing
        if #available(macOS 26, *), let accessory = syncAccessory as? NSSplitViewItemAccessoryViewController {
            accessory.isHidden = !shown.syncing
        }
        if shown.searchRequests != searchRequests {
            searchRequests = shown.searchRequests
            view.window?.makeFirstResponder(searchField)
        }
        updateItems(inLocked: shown.inLocked)
        view.needsLayout = true
    }

    /// The folders above the chats, then the chats, for the table.
    private static func rows(_ chats: [ChatSummary], model: AppModel, state: SidebarState, inLocked: Bool) -> [SidebarRow] {
        var rows: [SidebarRow] = []
        if state.query.isEmpty, !state.showingArchived, !inLocked, state.filter == .all, state.label == nil {
            if model.chats.lockedCount > 0 {
                rows.append(.folder(id: "locked", title: String(localized: "Locked Chats"), systemImage: "lock", count: nil) { [model] in
                    model.openLockedChats()
                })
            }
            if model.chats.archivedCount > 0 {
                rows.append(.folder(id: "archived", title: String(localized: "Archived"), systemImage: "archivebox", count: model.chats.archivedUnread) { [state, model] in
                    state.showingArchived = true
                    model.forgetKeptUnread()
                })
            }
        }
        rows += chats.map(SidebarRow.chat)
        return rows
    }

    // MARK: Layout

    private func place() {
        let bounds = view.bounds
        var top = view.safeAreaInsets.top
        var bottom: CGFloat = 0
        if !usesAccessories {
            searchBar.frame = CGRect(x: 0, y: top, width: bounds.width, height: Self.searchBarHeight)
            top += Self.searchBarHeight
            let height = sync.isHidden ? 0 : sync.intrinsicContentSize.height
            sync.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
            bottom = height
        }
        table.setTopInset(top)
        let below = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - bottom))
        tableScroll.frame = below
        let content = CGRect(x: 0, y: top, width: bounds.width, height: max(0, below.height - top))
        results.frame = content
        empty.frame = content
        presenters.frame = CGRect(x: 0, y: top, width: 1, height: 1)
    }

    /// The accessory pads its view itself; the bar only holds the field.
    private static var searchBarHeight: CGFloat {
        if #available(macOS 26, *) { 30 } else { 44 }
    }

    private static var searchInset: CGFloat {
        if #available(macOS 26, *) { 0 } else { 10 }
    }

    // MARK: Search

    public func controlTextDidChange(_ notification: Notification) {
        let query = searchField.stringValue
        guard query != state.query else { return }
        state.query = query
        state.cursor = nil
        model.searchMessages(query)
    }

    /// Escape clears the search, then leaves the field. While searching, ↓
    /// and ↑ walk the chats found, and Return opens the one reached (the
    /// first, when none) and leaves the search, as upstream's do.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty {
                view.window?.makeFirstResponder(nil)
            } else {
                setQuery("")
            }
            return true
        case #selector(NSResponder.moveDown(_:)):
            return moveCursor(down: true)
        case #selector(NSResponder.moveUp(_:)):
            return moveCursor(down: false)
        case #selector(NSResponder.insertNewline(_:)):
            return openCursor()
        default:
            return false
        }
    }

    /// Whether the arrow keys and Return walk the results: while searching
    /// chats, not in Locked Chats.
    private var walksResults: Bool {
        !state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.lockedChats.isOpen
    }

    private func moveCursor(down: Bool) -> Bool {
        guard walksResults else { return false }
        state.cursor = SearchCursor.moved(from: state.cursor, in: shownIDs, down: down)
        return true
    }

    private func openCursor() -> Bool {
        guard walksResults else { return false }
        guard let id = SearchCursor.opened(from: state.cursor, in: shownIDs) else { return true }
        setQuery("")
        // The field lets go so the chat can take the keyboard.
        view.window?.makeFirstResponder(nil)
        model.keepUnread(id)
        model.selectedChatID = id
        return true
    }

    private func setQuery(_ query: String) {
        searchField.stringValue = query
        guard state.query != query else { return }
        state.query = query
        state.cursor = nil
        model.searchMessages(query)
    }

    // MARK: Toolbar

    /// The sidebar's items for its window's toolbar.
    public func toolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        if let item = items[identifier] { return item }
        let item: NSToolbarItem
        switch identifier {
        case Self.filterItem:
            let menuItem = NSMenuToolbarItem(itemIdentifier: identifier)
            let menu = NSMenu()
            menu.delegate = self
            menuItem.menu = menu
            menuItem.showsIndicator = true
            menuItem.label = String(localized: "Filter")
            menuItem.toolTip = String(localized: "Filter chats")
            item = menuItem
        case Self.newChatItem:
            item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
            item.label = String(localized: "New Chat")
            item.toolTip = String(localized: "Start a new chat (⌘N)")
            item.isBordered = true
            item.target = self
            item.action = #selector(newChat)
        case Self.accountsItem:
            guard let accountsMenu else { return nil }
            let menuItem = NSMenuToolbarItem(itemIdentifier: identifier)
            let menu = NSMenu()
            menu.delegate = accountsMenu
            menuItem.menu = menu
            menuItem.showsIndicator = false
            menuItem.label = String(localized: "Accounts")
            menuItem.toolTip = String(localized: "Switch or add a WhatsApp account")
            item = menuItem
            items[identifier] = item
            observeAccountsItem()
            return item
        case Self.backItem:
            item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: nil)
            item.isBordered = true
            item.target = self
            item.action = #selector(goBack)
        default:
            return nil
        }
        items[identifier] = item
        updateItems(inLocked: model.lockedChats.isOpen)
        return item
    }

    /// Sets only what changed: any change to an item lays the toolbar out
    /// again, and this runs for every message.
    private func updateItems(inLocked: Bool) {
        let away = inLocked || state.showingArchived
        let filtering = state.filter != .all || state.label != nil
        let shown = ItemsState(away: away, inLocked: inLocked, filtering: filtering)
        guard shown != itemsState || items.count != itemsStateCount else { return }
        itemsState = shown
        itemsStateCount = items.count
        items[Self.filterItem]?.isHidden = away
        items[Self.newChatItem]?.isHidden = away
        if let back = items[Self.backItem] {
            back.isHidden = !away
            back.label = inLocked ? String(localized: "Lock and Go Back") : String(localized: "Back to Chats")
            back.toolTip = inLocked ? String(localized: "Lock these chats again and go back") : back.label
        }
        items[Self.filterItem]?.image = NSImage(
            systemSymbolName: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
            accessibilityDescription: nil
        )
    }

    private struct ItemsState: Equatable {
        var away: Bool
        var inLocked: Bool
        var filtering: Bool
    }

    private var itemsState: ItemsState?
    /// Items made since the state was last applied are set up too.
    private var itemsStateCount = 0

    /// Our picture, with a dot while another account has unread chats.
    private func observeAccountsItem() {
        guard let hub = model.hub, let item = items[Self.accountsItem] else { return }
        accountsObserved += 1
        let round = accountsObserved
        let model = model
        let shown = withObservationTracking {
            (picture: model.accountPicture,
             version: model.session.account.map { model.avatars.version(for: $0.id) } ?? 0,
             elsewhere: hub.unreadElsewhere > 0 && !model.appLock.isLocked)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.accountsObserved == round else { return }
                    self.observeAccountsItem()
                }
            }
        }
        item.image = AccountPicture.image(url: shown.picture, size: 22, dot: shown.elsewhere)
        _ = shown.version
    }

    @objc private func newChat() {
        model.newChatShown = true
    }

    @objc private func goBack() {
        if model.lockedChats.isOpen {
            model.closeLockedChats()
        } else {
            state.showingArchived = false
            model.forgetKeptUnread()
        }
    }

    // MARK: Filter menu

    /// Mail's filter menu: the built-in filters, muting every channel, and
    /// the labels, built as it opens.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: String(localized: "Show")))
        for filter in ChatFilter.allCases {
            let item = NSMenuItem(title: filter.name, action: #selector(pickFilter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = filter.rawValue
            item.state = state.label == nil && state.filter == filter ? .on : .off
            menu.addItem(item)
        }
        if model.chats.channelCount > 0 {
            menu.addItem(.separator())
            let muted = model.allChannelsMuted
            let item = NSMenuItem(
                title: muted ? String(localized: "Unmute All Channels") : String(localized: "Mute All Channels"),
                action: #selector(muteChannels), keyEquivalent: ""
            )
            item.target = self
            item.image = NSImage(systemSymbolName: muted ? "bell" : "bell.slash", accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "Labels")))
        for label in model.chats.labels {
            let item = NSMenuItem(title: label.name, action: #selector(pickLabel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = label.id
            item.image = ColorSwatch.nsImage(hex: label.colorHex)
            item.state = state.label == label.id ? .on : .off
            menu.addItem(item)
        }
        let manage = NSMenuItem(title: String(localized: "Manage Labels…"), action: #selector(manageLabels), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
    }

    @objc private func pickFilter(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let filter = ChatFilter(rawValue: raw) else { return }
        state.label = nil
        state.filter = filter
        model.forgetKeptUnread()
    }

    @objc private func pickLabel(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        if state.label == id {
            state.label = nil
            state.filter = .all
        } else {
            state.label = id
        }
        model.forgetKeptUnread()
    }

    @objc private func muteChannels() {
        model.muteAllChannels(!model.allChannelsMuted)
    }

    @objc private func manageLabels() {
        model.labelsManagerShown = true
    }
}

/// The sidebar's sheets: a new chat, the labels, unlocking Locked Chats.
private struct SidebarPresenters: View {
    @Bindable var model: AppModel

    var body: some View {
        Color.clear
            .sheet(isPresented: $model.newChatShown) {
                NewChatSheet(model: model)
            }
            .sheet(isPresented: $model.labelsManagerShown) {
                LabelManagerSheet(model: model)
            }
            .sheet(isPresented: $model.lockedChatsPrompt) {
                LockedChatsSheet(model: model)
            }
            .tint(model.chatTheme(for: nil).accent)
    }
}

/// Lays itself out through its controller.
private final class SidebarView: NSView {
    var onLayout: () -> Void = {}

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout()
    }
}

private extension LinkState {
    var isDisconnected: Bool {
        if case .disconnected = self { true } else { false }
    }
}
