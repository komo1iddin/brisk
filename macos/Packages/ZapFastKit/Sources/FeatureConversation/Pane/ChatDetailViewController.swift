import AppKit
import Observation
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// An open chat in an AppKit window: its wallpaper, the chat's pane
/// (timeline and composer), and the parts of the window that belong to the
/// chat: the header, search and actions in the toolbar, the search in the
/// inspector, and the sheets and dialogs SwiftUI presents. The main window
/// follows the chat picked in the sidebar; a chat's own window shows one.
///
/// SwiftUI is used only in islands that lay out on their own changes: the
/// header, the menus, the sheets' presenter and what floats over the
/// timeline. The window's size never goes through SwiftUI layout.
public final class ChatDetailViewController: NSViewController {
    public enum Source {
        /// The chat open in the main window.
        case selected
        /// One chat, in a window of its own.
        case chat(String)
    }

    public static let headerItem = NSToolbarItem.Identifier("ZapFastChatHeader")
    public static let searchItem = NSToolbarItem.Identifier("ZapFastChatSearch")
    public static let actionsItem = NSToolbarItem.Identifier("ZapFastChatActions")
    public static let callItem = NSToolbarItem.Identifier("ZapFastChatCall")
    public static let videoCallItem = NSToolbarItem.Identifier("ZapFastChatVideoCall")

    public let model: AppModel
    private let source: Source
    public private(set) var chatID: String?
    /// The chat's name, for the window's title in the Window menu and the
    /// Dock; nil while no chat is open.
    public private(set) var chatTitle: String?
    /// Whether the chat's search is open, which shows the inspector.
    public private(set) var searchShown = false
    /// The title or the search changed.
    public var onChange: () -> Void = {}

    /// The inspector's content: the open chat's search.
    public private(set) lazy var inspectorController: NSViewController = {
        let controller = NSHostingController(rootView: AnyView(EmptyView()))
        controller.sizingOptions = []
        return controller
    }()

    private var conversation: ConversationViewController?
    private let chrome = ConversationChrome()
    private let wallpaper = PassiveHostingView(rootView: AnyView(EmptyView()))
    private let placeholder = PassiveHostingView(rootView: AnyView(EmptyView()))
    private let presenters = PassiveHostingView(rootView: AnyView(EmptyView()))
    /// The fine line between the chat list and the chat.
    private let divider = HairlineView()
    private var header: NSHostingView<AnyView>?
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var observed = 0
    /// The open chat as its menu shows it, and as its header does.
    private var shownChat: ChatSummary?
    private var shownHeader: ConversationHeader.Content?

    public init(model: AppModel, source: Source) {
        self.model = model
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override public func loadView() {
        let view = DetailView()
        view.wantsLayer = true
        view.canAccept = { [weak self] in
            guard let self, let chatID = self.chatID else { return false }
            return self.model.chats.chat(chatID)?.canSend ?? true
        }
        view.onDrop = { [weak self] files in
            guard let self, let chatID = self.chatID else { return }
            self.model.stage(files: files, in: chatID)
        }
        for island in [wallpaper, placeholder, presenters, divider] as [NSView] {
            view.addSubview(island)
        }
        wallpaper.sizingOptions = []
        placeholder.sizingOptions = []
        presenters.sizingOptions = []
        placeholder.rootView = AnyView(
            ContentUnavailableView(
                "No chat selected",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Choose a chat from the list.")
            )
        )
        view.onLayout = { [weak self] in self?.place() }
        self.view = view
        observe()
    }

    // MARK: Following the chat

    private func observe() {
        observed += 1
        let round = observed
        let model = model
        let source = source
        let state = withObservationTracking {
            let id: String? = switch source {
            case .selected: model.selectedChatID
            case .chat(let id): id
            }
            let chat = id.flatMap { model.chats.chat($0) }
            let title = chat.map { model.chats.title(for: $0) }
            return (
                id: id,
                chat: chat?.withoutActivity,
                // Names are read here, where reading them costs nothing:
                // read in the header, they made SwiftUI and the toolbar lay
                // it out again for every message in any chat.
                header: chat.map { chat in
                    ConversationHeader.Content(
                        chat: chat.withoutActivity, title: title ?? "",
                        members: chat.kind == .group ? model.chats.participantNames(chat) : ""
                    )
                },
                title: title,
                search: id.map { model.search.chat?.chat == $0 } ?? false
            )
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.observed == round else { return }
                    self.observe()
                }
            }
        }
        if state.id != chatID { show(state.id) }
        // Another chat is another value too.
        if state.chat != shownChat {
            shownChat = state.chat
            updateMenu()
        }
        if state.header != shownHeader {
            shownHeader = state.header
            updateHeader()
        }
        if state.title != chatTitle || state.search != searchShown {
            chatTitle = state.title
            searchShown = state.search
            onChange()
        }
    }

    private func show(_ id: String?) {
        chatID = id
        chrome.infoRequest = nil
        let model = model
        if let id {
            if let conversation {
                conversation.show(chatID: id)
            } else {
                let chrome = chrome
                let conversation = ConversationViewController(chatID: id, model: model) { chrome.infoRequest = $0 }
                addChild(conversation)
                view.addSubview(conversation.view, positioned: .above, relativeTo: wallpaper)
                self.conversation = conversation
            }
            wallpaper.rootView = AnyView(ChatWallpaper(chatID: id, model: model))
            presenters.rootView = AnyView(ConversationPresenters(chatID: id, model: model, chrome: chrome))
        } else {
            conversation?.view.removeFromSuperview()
            conversation?.removeFromParent()
            conversation = nil
            wallpaper.rootView = AnyView(EmptyView())
            presenters.rootView = AnyView(EmptyView())
        }
        placeholder.isHidden = id != nil
        (inspectorController as? NSHostingController<AnyView>)?.rootView = AnyView(ConversationInspector(chatID: id, model: model))
        view.needsLayout = true
    }

    /// The wallpaper fills the view, under a floating sidebar too; the
    /// chat keeps clear of what floats beside it, and runs under the title
    /// bar, where its pane insets the first row.
    private func place() {
        let bounds = view.bounds
        let insets = view.safeAreaInsets
        let content = CGRect(
            x: insets.left, y: 0,
            width: max(0, bounds.width - insets.left - insets.right), height: bounds.height
        )
        wallpaper.frame = bounds
        conversation?.view.frame = content
        placeholder.frame = content
        presenters.frame = CGRect(x: content.minX, y: 0, width: 1, height: 1)
        divider.frame = CGRect(x: content.minX, y: 0, width: HairlineView.thickness(in: view.window), height: bounds.height)
    }

    // MARK: Toolbar

    /// The chat's items for its window's toolbar: the header, search and
    /// the chat's menu.
    public func toolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        if let item = items[identifier] { return item }
        let item: NSToolbarItem
        switch identifier {
        case Self.headerItem:
            let host = NSHostingView(rootView: AnyView(EmptyView()))
            host.sizingOptions = [.intrinsicContentSize]
            header = host
            item = TitleToolbarItem(itemIdentifier: identifier)
            item.view = host
            item.label = String(localized: "Chat")
            item.visibilityPriority = .high
        case Self.searchItem:
            item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            item.label = String(localized: "Search in Chat")
            item.toolTip = String(localized: "Search in this chat (⌘F)")
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleSearch)
        case Self.callItem:
            item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "phone", accessibilityDescription: nil)
            item.label = String(localized: "Voice Call")
            item.toolTip = String(localized: "Voice call")
            item.isBordered = true
            item.target = self
            item.action = #selector(call)
        case Self.videoCallItem:
            item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "video", accessibilityDescription: nil)
            item.label = String(localized: "Video Call")
            item.toolTip = String(localized: "Video call")
            item.isBordered = true
            item.target = self
            item.action = #selector(videoCall)
        case Self.actionsItem:
            let menuItem = NSMenuToolbarItem(itemIdentifier: identifier)
            menuItem.showsIndicator = true
            menuItem.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
            menuItem.label = String(localized: "Chat")
            menuItem.toolTip = String(localized: "Chat actions")
            item = menuItem
        default:
            return nil
        }
        items[identifier] = item
        updateMenu()
        updateHeader()
        return item
    }

    // The header and the menu show the chat as they were given it: they are
    // made again when what they show of it changes, not for each message
    // (the menu, rebuilt by SwiftUI, cost a few milliseconds a message).

    private func updateHeader() {
        if let content = shownHeader {
            header?.rootView = AnyView(ConversationHeader(content: content, model: model, chrome: chrome))
        } else {
            header?.rootView = AnyView(EmptyView())
        }
    }

    private func updateMenu() {
        // A menu of its own each time: changing a hosting menu's root view
        // once it was made stops SwiftUI.
        let actions = items[Self.actionsItem] as? NSMenuToolbarItem
        if let chat = shownChat {
            actions?.menu = NSHostingMenu(rootView: ChatActions(chat: chat, model: model))
        } else {
            actions?.menu = NSMenu()
        }
        for item in items.values {
            item.isHidden = shownChat == nil
        }
        items[Self.callItem]?.isHidden = !Self.canCall(shownChat, model: model)
        items[Self.videoCallItem]?.isHidden = !Self.canCall(shownChat, model: model) || shownChat?.kind != .direct
    }

    /// A person's chat, other than our own, can be called, and so can a
    /// group we are still in (with voice only).
    static func canCall(_ chat: ChatSummary?, model: AppModel) -> Bool {
        guard let chat, !chat.isChannel else { return false }
        switch chat.kind {
        case .direct: return !chat.readOnly && !model.session.isOurs(chat.id)
        case .group: return !chat.left
        case .broadcast: return false
        }
    }

    @objc private func call() {
        guard let chatID else { return }
        let calls = model.calls
        Task { await calls.place(chat: chatID) }
    }

    @objc private func videoCall() {
        guard let chatID else { return }
        let calls = model.calls
        Task { await calls.place(chat: chatID, video: true) }
    }

    @objc private func toggleSearch() {
        guard let chatID else { return }
        if model.search.chat?.chat == chatID {
            model.closeChatSearch()
        } else {
            model.openChatSearch(in: chatID)
        }
    }
}

/// The chat's wallpaper, following its theme.
private struct ChatWallpaper: View {
    let chatID: String
    let model: AppModel

    var body: some View {
        WallpaperView(model.chatTheme(for: chatID).wallpaper)
    }
}

/// The header's item, without the glass capsule AppKit puts behind a
/// toolbar item on macOS 26: the chat's name is a title, as SwiftUI's
/// header was with `sharedBackgroundVisibility(.hidden)`.
///
/// AppKit has no public switch for this yet. The toolbar asks each item
/// for `glassBehavior`, and 0 is what spaces and the window's own title
/// answer. Should AppKit stop asking, the header only gains a capsule.
private final class TitleToolbarItem: NSToolbarItem {
    @objc var glassBehavior: Int { 0 }
}

/// A vertical line one device pixel wide in the separator colour, over the
/// edge where the chat list ends. A picture only.
private final class HairlineView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static func thickness(in window: NSWindow?) -> CGFloat {
        1 / (window?.backingScaleFactor ?? 2)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Lays itself out through its controller, and takes files dropped on the
/// chat into the composer.
private final class DetailView: NSView {
    var onLayout: () -> Void = {}
    var canAccept: () -> Bool = { false }
    var onDrop: ([URL]) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        files(sender).isEmpty || !canAccept() ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let files = files(sender)
        guard !files.isEmpty, canAccept() else { return false }
        onDrop(files)
        return true
    }

    private func files(_ sender: any NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (urls as? [URL]) ?? []
    }
}
