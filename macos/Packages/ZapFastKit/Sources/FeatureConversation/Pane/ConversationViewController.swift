import AppKit
import Observation
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// What the islands over the timeline show of it: the "newest message"
/// button, the empty chat's note and the spinner while older messages come.
@Observable
final class ConversationPaneState {
    var scroll = TimelineController.ScrollState()
    /// The chat has nothing, once the archive and phone have said so.
    var empty = false
    /// Older messages are on their way, from the archive or the phone.
    var loadingOlder = false
    /// The chat, without its latest activity, while it takes no messages
    /// from us; the composer's place says why.
    var closedChat: ChatSummary?
}

/// An open chat, in AppKit: the timeline is a plain subview, and around it
/// sit small SwiftUI islands: what floats over the timeline (the spinner
/// while older messages come, the "newest message" button, the empty
/// chat's note) and the composer. `ChatDetailViewController` holds it,
/// with the wallpaper behind it.
///
/// When the timeline was a SwiftUI view among the composer and overlays,
/// every row the table added or moved while scrolling sent all of them
/// through SwiftUI layout and rendering again, a tenth of the main thread,
/// and AppKit's cursor updates hit-tested them on every frame. Now that
/// work stops at this view.
final class ConversationViewController: NSViewController {
    let model: AppModel
    private(set) var chatID: String
    private let timeline = TimelineController()
    private let pane = ConversationPaneState()
    private let overlay = IslandHostingView(rootView: AnyView(EmptyView()))
    private let newest = IslandHostingView(rootView: AnyView(EmptyView()))
    private let bottomBar = NSHostingView(rootView: AnyView(EmptyView()))
    private let titleBand = TitleBandView()
    private var observed = 0

    init(chatID: String, model: AppModel) {
        self.chatID = chatID
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let view = PaneView()
        view.wantsLayer = true
        let scrollView = timeline.makeScrollView()
        // The title bar's inset comes from AppKit.
        for island in [scrollView, titleBand, overlay, newest, bottomBar] as [NSView] {
            island.frame = view.bounds
            view.addSubview(island)
        }
        overlay.sizingOptions = []
        newest.sizingOptions = []
        // A picture only: clicks and scrolling go to the timeline under it.
        overlay.passesThrough = { _ in true }
        // Only the button itself, while it shows, takes the pointer: the
        // 34-point circle in the middle of the island.
        newest.passesThrough = { [pane] point in
            let middle = NewestMessageIsland.size / 2
            return pane.scroll.atBottom || hypot(point.x - middle, point.y - middle) > 17
        }
        // The composer sizes itself; the timeline ends where it starts.
        bottomBar.sizingOptions = [.intrinsicContentSize]
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.onLayout = { [weak self] in self?.placeTimeline() }
        self.view = view
        // The pane's state first: the islands show it.
        observeTimeline()
        showIslands()
    }

    /// Another chat in the same place: the timeline, composer and islands
    /// follow; the one opened fades in, as the SwiftUI view did.
    func show(chatID: String) {
        guard chatID != self.chatID else { return }
        self.chatID = chatID
        pane.scroll = .init()
        observeTimeline()
        showIslands()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1
        }
    }

    // MARK: Islands

    private func showIslands() {
        let chatID = chatID
        let model = model
        overlay.rootView = AnyView(ConversationOverlay(pane: pane).chatStyle(chatID, model: model))
        newest.rootView = AnyView(NewestMessageIsland(pane: pane) { model.scrollTimeline(.bottom) }.chatStyle(chatID, model: model))
        // A new composer for each chat, as the SwiftUI view made one.
        bottomBar.rootView = AnyView(ConversationBottomBar(chatID: chatID, model: model, pane: pane).id(chatID).chatStyle(chatID, model: model))
    }

    /// The timeline scrolls under the title bar, its first row inset clear
    /// of it, and ends where the composer starts, as the SwiftUI view's
    /// safe area inset placed it. What floats over it covers the same
    /// place; the "newest message" button sits just above the composer.
    private func placeTimeline() {
        let bounds = view.bounds
        let bar = bottomBar.frame.height
        let frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - bar))
        let top = view.safeAreaInsets.top
        titleBand.frame = CGRect(x: 0, y: 0, width: bounds.width, height: top)
        titleBand.isHidden = top == 0
        overlay.frame = frame
        let size = NewestMessageIsland.size
        newest.frame = CGRect(x: bounds.width - Metrics.l - size + 8, y: frame.maxY - Metrics.l - size + 8, width: size, height: size)
        timeline.place(frame: frame, topInset: top)
    }

    // MARK: The timeline

    /// Hands the timeline what it shows, now and whenever any of it
    /// changes: this chat's messages, its theme, the text size, the unread
    /// divider, jumps and scrolls. Picking messages each row watches itself.
    private func observeTimeline() {
        observed += 1
        let round = observed
        let model = model
        let chatID = chatID
        let pane = pane
        let inputs = withObservationTracking {
            let conversation = model.conversations.conversation(chatID)
            let chat = model.chats.chat(chatID)
            return (
                closedChat: chat.flatMap { $0.canSend ? nil : $0.withoutActivity },
                empty: conversation.requested && conversation.messages.isEmpty && !conversation.fetchingPhone,
                loadingOlder: conversation.loadingOlder || conversation.fetchingPhone,
                messages: conversation.messages,
                revision: conversation.messagesRevision,
                isGroup: chat?.kind == .group,
                style: TimelineStyle(theme: model.chatTheme(for: chatID), textScale: model.preferences.textScale),
                unread: model.unreadDivider?.chat == chatID ? model.unreadDivider : nil,
                jump: model.jump,
                scroll: model.timelineScroll
            )
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.observed == round else { return }
                    self.observeTimeline()
                }
            }
        }
        // Set when they change only: the islands that show them would be
        // made again by every message otherwise.
        if pane.empty != inputs.empty { pane.empty = inputs.empty }
        if pane.loadingOlder != inputs.loadingOlder { pane.loadingOlder = inputs.loadingOlder }
        if pane.closedChat != inputs.closedChat { pane.closedChat = inputs.closedChat }
        timeline.update(
            chatID: chatID,
            messages: inputs.messages,
            revision: inputs.revision,
            isGroup: inputs.isGroup,
            model: model,
            style: inputs.style,
            unread: inputs.unread,
            jump: inputs.jump,
            scrollRequest: inputs.scroll,
            onReachTop: { model.loadOlder(in: chatID) },
            onScrollState: { pane.scroll = $0 }
        )
    }
}

/// The title bar's frosted band over the top of the timeline, with a
/// hairline under it, as SwiftUI's window drew it: what scrolls under the
/// toolbar shows through blurred, never sharp over the header.
///
/// AppKit's own edge effect needs a background the scroll view draws
/// itself; the timeline's is the wallpaper behind it, so AppKit left the
/// edge clear and the chat ran sharply under the toolbar.
final class TitleBandView: NSVisualEffectView {
    private let hairline = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .titlebar
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        wantsLayer = true
        hairline.actions = ["frame": NSNull(), "position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(hairline)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        hairline.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        updateHairline()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHairline()
    }

    private func updateHairline() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            hairline.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    /// A picture only: the toolbar above it takes the clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A SwiftUI island over or under the timeline that lets the pointer
/// through where `passesThrough` says, in its own flipped coordinates.
final class IslandHostingView: NSHostingView<AnyView> {
    var passesThrough: (NSPoint) -> Bool = { _ in false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        let flipped = NSPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
        return passesThrough(flipped) ? nil : super.hitTest(point)
    }
}

/// Lays itself out through its controller: the composer's height sets
/// where the timeline ends.
private final class PaneView: NSView {
    var onLayout: () -> Void = {}

    override func layout() {
        super.layout()
        onLayout()
    }

    override var isFlipped: Bool { true }
}

private extension View {
    /// Each island is a SwiftUI root of its own: the chat's theme and tint,
    /// which the conversation view gave everything under it, are given again.
    func chatStyle(_ chatID: String, model: AppModel) -> some View {
        modifier(ChatStyle(chatID: chatID, model: model))
    }
}

private struct ChatStyle: ViewModifier {
    let chatID: String
    let model: AppModel

    func body(content: Content) -> some View {
        let theme = model.chatTheme(for: chatID)
        content
            .environment(\.chatTheme, theme)
            .tint(theme.accent)
            .opensInviteLinks(model: model)
    }
}
