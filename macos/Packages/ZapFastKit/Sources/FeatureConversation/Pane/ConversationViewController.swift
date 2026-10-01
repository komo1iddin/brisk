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
        let soft = BottomBandView.fade
        bottomBand.frame = CGRect(x: 0, y: max(0, bounds.height - bar - soft), width: bounds.width, height: min(bounds.height, bar + soft))
        bottomBand.isHidden = bar == 0
        overlay.frame = frame
        let size = NewestMessageIsland.size
        newest.frame = CGRect(x: bounds.width - Metrics.l - size + 8, y: frame.maxY - Metrics.l - size + 8, width: size, height: size)
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

/// The blur at the foot of the timeline, behind the composer: the chat
/// blurs progressively toward the bottom edge, sharp where it starts and
/// softest under the composer, instead of ending at a hard line above the
/// controls, as in WhatsApp. The blur is the window server's own, varied by
/// a gradient, with no tint of its own: the wallpaper stays its colour.
///
/// The filter is Core Animation's, which is not published. Where it is not
/// there the chat simply runs under the composer.
final class BottomBandView: NSView {
    /// How far above the composer the blur begins.
    static let fade: CGFloat = 48
    /// The strongest blur, in points, at the bottom edge.
    private static let radius = 8.0
    private let backdrop: CALayer?
    private let filter: NSObject?
    private var maskSize = CGSize.zero

    override init(frame: NSRect) {
        let made = Self.makeBlur()
        backdrop = made?.layer
        filter = made?.filter
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        if let backdrop { layer?.addSublayer(backdrop) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private static func makeBlur() -> (layer: CALayer, filter: NSObject)? {
        guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let make = NSSelectorFromString("filterWithType:")
        guard filterClass.responds(to: make),
              let filter = filterClass.perform(make, with: "variableBlur")?.takeUnretainedValue() as? NSObject else { return nil }
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        let layer = backdropClass.init()
        layer.filters = [filter]
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        return (layer, filter)
    }

    override func layout() {
        super.layout()
        guard let backdrop, let filter else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        // The mask is as large as the view, as many pixels as it shows.
        if bounds.size != maskSize, bounds.height > 0 {
            maskSize = bounds.size
            let scale = window?.backingScaleFactor ?? 2
            filter.setValue(Self.mask(size: bounds.size, scale: scale), forKey: "inputMaskImage")
            backdrop.filters = [filter]
        }
        CATransaction.commit()
    }

    /// Opaque black at the foot, clear at the top, eased: where the mask is
    /// opaque the blur is at its full radius. Row 0 is the top.
    private static func mask(size: CGSize, scale: CGFloat) -> CGImage? {
        let width = 4
        let height = max(2, Int((size.height * scale).rounded()))
        let space = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: width * height * 2)
        for row in 0..<height {
            let t = Double(row) / Double(height - 1)
            // The blur begins `fade` points above the composer and is whole
            // under it: the first stretch eases in from nothing.
            let ramp = min(1, t / (Double(fade) / Double(size.height)))
            let alpha = ramp * ramp * (3 - 2 * ramp)
            for column in 0..<width {
                let index = (row * width + column) * 2
                pixels[index] = 0
                pixels[index + 1] = UInt8((alpha * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 16, bytesPerRow: width * 2,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// A picture only: the composer and the timeline take the pointer.
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
