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
    private let bottomBand = BottomBandView()
    private var observed = 0

    init(chatID: String, model: AppModel, onInfoRequest: @escaping (InfoRequest) -> Void) {
        self.chatID = chatID
        self.model = model
        super.init(nibName: nil, bundle: nil)
        timeline.onInfoRequest = onInfoRequest
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let view = PaneView()
        view.wantsLayer = true
        let scrollView = timeline.makeScrollView()
        // The title bar's inset comes from AppKit.
        for island in [scrollView, titleBand, bottomBand, overlay, newest, bottomBar] as [NSView] {
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
    /// follow, and the chat just left dissolves into the one opened. The
    /// dissolve is one pass of the compositor over what is already drawn,
    /// no more work for the main thread than the switch itself.
    func show(chatID: String) {
        guard chatID != self.chatID else { return }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let dissolve = CATransition()
            dissolve.type = .fade
            dissolve.duration = 0.2
            dissolve.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            view.layer?.add(dissolve, forKey: "chatSwitch")
        }
        self.chatID = chatID
        pane.scroll = .init()
        observeTimeline()
        showIslands()
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

    /// The timeline scrolls under the title bar and under the composer, its
    /// first row inset clear of the one and its last of the other, as the
    /// SwiftUI view's safe area insets placed it. What floats over it ends
    /// where the composer starts; the "newest message" button sits just
    /// above it.
    private func placeTimeline() {
        let bounds = view.bounds
        let bar = bottomBar.frame.height
        let frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - bar))
        let top = view.safeAreaInsets.top
        titleBand.frame = CGRect(x: 0, y: 0, width: bounds.width, height: top)
        titleBand.isHidden = top == 0
        let soft = (bar * BottomBandView.share).rounded()
        bottomBand.frame = CGRect(x: 0, y: max(0, bounds.height - soft), width: bounds.width, height: min(bounds.height, soft))
        bottomBand.isHidden = bar == 0
        overlay.frame = frame
        let size = NewestMessageIsland.size
        // In the microphone's column, just above the composer: the island is
        // 8 points wider than its button on each side.
        newest.frame = CGRect(x: bounds.width - Metrics.m - size + 8, y: frame.maxY - Metrics.s - size + 8, width: size, height: size)
        timeline.place(frame: CGRect(origin: .zero, size: bounds.size), topInset: top, bottomInset: bar)
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
                calls: model.calls.history.calls(in: chatID),
                fromStart: conversation.complete,
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
            calls: inputs.calls,
            fromStart: inputs.fromStart,
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
/// hairline under it: what scrolls under the toolbar shows through,
/// blurred and veiled, as in WhatsApp's header, never sharp over it.
///
/// AppKit's own edge effect needs a background the scroll view draws
/// itself; the timeline's is the wallpaper behind it, so AppKit left the
/// edge clear and the chat ran sharply under the toolbar. The system
/// materials blur so far and tint so much that the band was nearly opaque,
/// and SwiftUI's thinnest material at times let the messages through
/// unblurred; a backdrop with a moderate blur under a light veil keeps the
/// wallpaper's doodles and the messages faintly there. Core Animation's
/// backdrop is not published: where it is missing, the title bar material
/// stands in.
final class TitleBandView: NSView {
    private let backdrop: CALayer?
    private let veil = CALayer()
    private let hairline = CALayer()
    private var fallback: NSVisualEffectView?

    /// The blur, in points, and how much of the window's colour veils it.
    static let blurRadius = 12.0
    static let veilLight = 0.62
    static let veilDark = 0.58

    override init(frame: NSRect) {
        backdrop = Self.makeBackdrop()
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        if let backdrop {
            layer?.addSublayer(backdrop)
            layer?.addSublayer(veil)
        } else {
            let material = NSVisualEffectView(frame: bounds)
            material.material = .titlebar
            material.blendingMode = .withinWindow
            material.state = .followsWindowActiveState
            material.autoresizingMask = [.width, .height]
            addSubview(material)
            fallback = material
        }
        for sublayer in [veil, hairline] {
            sublayer.actions = ["frame": NSNull(), "position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        }
        layer?.addSublayer(hairline)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private static func makeBackdrop() -> CALayer? {
        guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let make = NSSelectorFromString("filterWithType:")
        guard filterClass.responds(to: make),
              let blur = filterClass.perform(make, with: "gaussianBlur")?.takeUnretainedValue() as? NSObject,
              let saturate = filterClass.perform(make, with: "colorSaturate")?.takeUnretainedValue() as? NSObject else { return nil }
        blur.setValue(blurRadius, forKey: "inputRadius")
        blur.setValue(true, forKey: "inputNormalizeEdges")
        saturate.setValue(1.6, forKey: "inputAmount")
        let layer = backdropClass.init()
        layer.filters = [blur, saturate]
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        return layer
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop?.frame = bounds
        veil.frame = bounds
        hairline.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        CATransaction.commit()
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            veil.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(dark ? Self.veilDark : Self.veilLight).cgColor
            hairline.backgroundColor = NSColor.separatorColor.cgColor
        }
        CATransaction.commit()
    }

    /// A picture only: the toolbar above it takes the clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The soft edge at the foot of the timeline, behind the composer: the
/// chat goes from sharp to blurred toward the bottom edge instead of ending
/// at a hard line, as in WhatsApp. It begins about the middle of the field
/// and strengthens downward. A system material under a gradient mask: the
/// blur is the window server's, with the least tint a material has.
final class BottomBandView: NSHostingView<BottomBlur> {
    /// How much of the composer's height the blur covers, from its foot.
    static let share: CGFloat = 0.62

    init() {
        super.init(rootView: BottomBlur())
        sizingOptions = []
    }

    @available(*, unavailable)
    required init(rootView: BottomBlur) { fatalError("not used") }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A picture only: the composer and the timeline take the pointer.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct BottomBlur: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0), location: 0),
                        .init(color: .black.opacity(0.12), location: 0.3),
                        .init(color: .black.opacity(0.5), location: 0.65),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
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
