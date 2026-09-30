import AppKit
import Observation
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// What the "newest message" button needs from the timeline.
@Observable
final class ConversationPaneState {
    var scroll = TimelineController.ScrollState()
}

/// An open chat, in AppKit: the timeline is a plain subview, and around it
/// sit small SwiftUI islands: what floats over the timeline (the spinner
/// while older messages come, the "newest message" button, the empty
/// chat's note) and the composer. The wallpaper stays behind, in SwiftUI,
/// where it reaches under the sidebar.
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
        // The top inset is the title bar's, set here.
        scrollView.automaticallyAdjustsContentInsets = false
        for island in [scrollView, overlay, newest, bottomBar] as [NSView] {
            island.frame = view.bounds
            view.addSubview(island)
        }
        overlay.autoresizingMask = [.width, .height]
        overlay.sizingOptions = []
        newest.sizingOptions = []
        // A picture only: clicks and scrolling go to the timeline under it.
        overlay.passesThrough = { _ in true }
        // Only the button itself, while it shows, takes the pointer.
        newest.passesThrough = { [pane] point in
            pane.scroll.atBottom || point.x < NewestMessageIsland.size - 40 || point.y < NewestMessageIsland.size - 40
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
        showIslands()
        observeTimeline()
    }

    /// Another chat in the same place: the timeline, composer and islands
    /// follow; the one opened fades in, as the SwiftUI view did.
    func show(chatID: String) {
        guard chatID != self.chatID else { return }
        self.chatID = chatID
        pane.scroll = .init()
        showIslands()
        observeTimeline()
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
        overlay.rootView = AnyView(ConversationOverlay(chatID: chatID, model: model).chatStyle(chatID, model: model))
        newest.rootView = AnyView(NewestMessageIsland(pane: pane) { model.scrollTimeline(.bottom) }.chatStyle(chatID, model: model))
        // A new composer for each chat, as the SwiftUI view made one.
        bottomBar.rootView = AnyView(ConversationBottomBar(chatID: chatID, model: model).id(chatID).chatStyle(chatID, model: model))
    }

    /// The timeline scrolls under the title bar, its first row inset clear
    /// of it, and ends where the composer starts, as the SwiftUI view's
    /// safe area inset placed it. The "newest message" button sits just
    /// above the composer.
    private func placeTimeline() {
        let bounds = view.bounds
        let bar = bottomBar.frame.height
        let frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - bar))
        let top = view.safeAreaInsets.top
        let size = NewestMessageIsland.size
        newest.frame = CGRect(x: bounds.width - Metrics.l - size + 8, y: frame.maxY - Metrics.l - size + 8, width: size, height: size)
        timeline.place(frame: frame, topInset: top)
    }

    // MARK: The timeline

    /// Hands the timeline what it shows, now and whenever any of it
    /// changes: this chat's messages, its theme, the text size, the unread
    /// divider, whether messages are being picked, jumps and scrolls.
    private func observeTimeline() {
        observed += 1
        let round = observed
        let model = model
        let chatID = chatID
        let pane = pane
        let inputs = withObservationTracking {
            let conversation = model.conversations.conversation(chatID)
            return (
                messages: conversation.messages,
                revision: conversation.messagesRevision,
                isGroup: model.chats.chat(chatID)?.kind == .group,
                style: TimelineStyle(theme: model.chatTheme(for: chatID), textScale: model.preferences.textScale),
                unread: model.unreadDivider?.chat == chatID ? model.unreadDivider : nil,
                selecting: model.selection?.chat == chatID,
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
        timeline.update(
            chatID: chatID,
            messages: inputs.messages,
            revision: inputs.revision,
            isGroup: inputs.isGroup,
            model: model,
            style: inputs.style,
            unread: inputs.unread,
            selecting: inputs.selecting,
            jump: inputs.jump,
            scrollRequest: inputs.scroll,
            onReachTop: { model.loadOlder(in: chatID) },
            onScrollState: { pane.scroll = $0 }
        )
    }
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

/// The chat's AppKit pane in SwiftUI, in place of the timeline, overlays
/// and composer the conversation view drew itself.
struct ConversationPane: NSViewControllerRepresentable {
    let chatID: String
    let model: AppModel

    func makeNSViewController(context: Context) -> ConversationViewController {
        ConversationViewController(chatID: chatID, model: model)
    }

    /// Whatever it is offered, so SwiftUI never asks the pane's views for
    /// their size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: ConversationViewController, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 400))
    }

    func updateNSViewController(_ controller: ConversationViewController, context: Context) {
        controller.show(chatID: chatID)
    }
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
