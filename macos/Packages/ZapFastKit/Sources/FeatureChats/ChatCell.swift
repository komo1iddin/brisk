import AppKit
import Observation
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// What a chat's row shows, read from the model as `ChatRow` reads it. A
/// cell redraws only when this changes.
struct ChatRowContent: Equatable {
    enum Preview: Equatable {
        case typing(String)
        case draft(String)
        /// The last message, with ticks when it is the reader's own.
        case message(String, ticks: DeliveryTicks.State?)
        case nothing
    }

    enum Badge: Equatable {
        case count(UInt32)
        /// Marked unread, nothing counted.
        case dot
    }

    enum Placeholder: Equatable {
        case initials(String)
        case symbol(String)
    }

    var title: String
    var bold: Bool
    var time: String
    var timeAccented: Bool
    var preview: Preview
    var muted: Bool
    var pinned: Bool
    var badge: Badge?
    /// Messages disappear: a timer on the avatar.
    var disappearing: Bool
    var avatar: URL?
    var avatarVersion: Int
    var seed: String
    var placeholder: Placeholder
    /// The last message in full, for the tooltip.
    var full: String

    init(chat: ChatSummary, model: AppModel) {
        title = model.chats.title(for: chat)
        muted = model.chats.isMuted(chat)
        bold = chat.looksUnread
        time = DateText.chatRow(chat.lastActivity)
        timeAccented = chat.unread > 0 && !muted
        pinned = chat.pinned
        badge = chat.looksUnread ? (chat.unread > 0 ? .count(chat.unread) : .dot) : nil
        disappearing = (chat.ephemeralExpiration ?? 0) > 0
        avatar = model.avatars.url(for: chat.id)
        avatarVersion = model.avatars.version(for: chat.id)
        seed = chat.id
        placeholder = switch chat.kind {
        case .group: .symbol("person.2.fill")
        case .broadcast: .symbol("megaphone.fill")
        case .direct: .initials(AvatarView.initials(title))
        }
        full = chat.last?.full ?? ""

        let typing = model.conversations.typing(in: chat.id)
        if !typing.isEmpty {
            if chat.kind == .group, let first = typing.first {
                preview = .typing(String(localized: "\(model.chats.personName(first, hint: nil)) is typing…"))
            } else {
                preview = .typing(String(localized: "typing…"))
            }
        } else if let draft = model.chats.draft(for: chat.id), !draft.isEmpty, chat.id != model.selectedChatID {
            preview = .draft(draft)
        } else if let last = chat.last {
            var text = last.summary
            if chat.kind == .group, !last.fromMe {
                text = "\(model.chats.personName(last.sender, hint: last.senderName)): " + text
            }
            preview = .message(text, ticks: last.fromMe ? DeliveryTicks.State(last.status) : nil)
        } else {
            preview = .nothing
        }
    }

    /// What VoiceOver reads for the row, as SwiftUI combined `ChatRow`'s.
    var accessibilityLabel: String {
        var parts = [title, time]
        switch preview {
        case .typing(let text): parts.append(text)
        case .draft(let text): parts.append(String(localized: "Draft: ") + text)
        case .message(let text, let ticks):
            if let ticks { parts.append(ticks.label) }
            parts.append(text)
        case .nothing: break
        }
        if muted { parts.append(String(localized: "Muted")) }
        if disappearing { parts.append(String(localized: "Disappearing messages")) }
        if pinned { parts.append(String(localized: "Pinned")) }
        switch badge {
        case .count(let count): parts.append(String(localized: "\(count) unread"))
        case .dot: parts.append(String(localized: "Unread"))
        case nil: break
        }
        return parts.joined(separator: ", ")
    }
}

private extension DeliveryTicks.State {
    var label: String {
        switch self {
        case .pending: String(localized: "Sending")
        case .sent: String(localized: "Sent")
        case .delivered: String(localized: "Delivered")
        case .read: String(localized: "Read")
        case .failed: String(localized: "Not sent")
        }
    }
}

/// A chat in the sidebar, drawn by Core Animation and placed by frame. It
/// follows what it reads from the model (names, drafts, typing, the avatar)
/// itself, as the SwiftUI row did, and redraws only when what it shows
/// changed.
///
/// What SwiftUI draws in a secondary or tertiary style is vibrant in a
/// sidebar, blended with what is behind it, while the title and coloured
/// marks are not: the cell draws the row twice, once for each, in a view
/// that allows vibrancy and one over it that does not.
final class ChatCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarChatCellDrawn")

    private let vibrant = RowLayerView(vibrant: true)
    private let plain = RowLayerView(vibrant: false)
    private let avatarLayer = AvatarLayer()
    private let timer = CALayer()
    /// In the collapsed sidebar: the unread count on the picture.
    private let unread = CALayer()
    /// Only the picture, centred, with the unread count on it.
    var compact = false {
        didSet {
            guard compact != oldValue else { return }
            vibrantText.isHidden = compact
            plainText.isHidden = compact
            placeLayers(bounds.size)
            drawUnread()
        }
    }
    private let vibrantText = ChatRowLayer(pass: .vibrant)
    private let plainText = ChatRowLayer(pass: .plain)
    private(set) var chat: ChatSummary?
    private(set) var content: ChatRowContent?
    private weak var model: AppModel?
    private var observed = 0
    private var loads = 0
    private var shownPhoto: (url: URL?, version: Int)?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        addSubview(vibrant)
        addSubview(plain)
        vibrant.layer?.addSublayer(vibrantText)
        plain.layer?.addSublayer(avatarLayer)
        plain.layer?.addSublayer(plainText)
        timer.isHidden = true
        timer.actions = ["contents": NSNull(), "hidden": NSNull(), "position": NSNull(), "bounds": NSNull()]
        plain.layer?.addSublayer(timer)
        unread.isHidden = true
        unread.actions = ["contents": NSNull(), "hidden": NSNull(), "position": NSNull(), "bounds": NSNull()]
        plain.layer?.addSublayer(unread)
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func show(_ chat: ChatSummary, model: AppModel) {
        self.chat = chat
        self.model = model
        observe()
    }

    /// Stops following the model while the cell waits for reuse.
    func stopObserving() {
        observed += 1
        chat = nil
    }

    private func observe() {
        guard let chat, let model else { return }
        observed += 1
        let round = observed
        let content = withObservationTracking {
            ChatRowContent(chat: chat, model: model)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.observed == round else { return }
                    self.observe()
                }
            }
        }
        apply(content)
    }

    private func apply(_ content: ChatRowContent) {
        guard content != self.content else { return }
        let old = self.content
        self.content = content
        for layer in [vibrantText, plainText] {
            layer.content = content
            layer.setNeedsDisplay()
        }
        if old?.placeholder != content.placeholder {
            avatarLayer.glyph.placeholder = content.placeholder
            avatarLayer.glyph.setNeedsDisplay()
        }
        if old?.seed != content.seed {
            avatarLayer.setColor(seed: content.seed, appearance: effectiveAppearance)
        }
        showPhoto(url: content.avatar, version: content.avatarVersion)
        if old?.disappearing != content.disappearing {
            timer.isHidden = !content.disappearing
            if content.disappearing { drawTimer() }
        }
        if old?.badge != content.badge { drawUnread() }
        setAccessibilityLabel(content.accessibilityLabel)
    }

    /// The profile picture over the placeholder, once there is one.
    private func showPhoto(url: URL?, version: Int) {
        guard shownPhoto.map({ $0.url != url || $0.version != version }) ?? true else { return }
        shownPhoto = (url, version)
        loads += 1
        let load = loads
        guard let url else {
            avatarLayer.setPhoto(nil)
            return
        }
        let points = ChatCellMetrics.avatar
        if let cached = Thumbnails.cached(url, points: points) {
            avatarLayer.setPhoto(cached)
            return
        }
        avatarLayer.setPhoto(nil)
        Task { [weak self] in
            let image = await Thumbnails.load(url, points: points)
            guard let self, self.loads == load else { return }
            self.avatarLayer.setPhoto(image)
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            guard emphasized != plainText.emphasized else { return }
            for layer in [vibrantText, plainText] {
                layer.emphasized = emphasized
                layer.setNeedsDisplay()
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        vibrant.frame = bounds
        plain.frame = bounds
        placeLayers(newSize)
    }

    private func placeLayers(_ newSize: NSSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = ChatCellMetrics.avatar
        let x = compact ? ((newSize.width - size) / 2).rounded() : 0
        avatarLayer.frame = CGRect(x: x, y: ((newSize.height - size) / 2).rounded(), width: size, height: size)
        let badge = Self.timerSize
        timer.frame = CGRect(
            x: avatarLayer.frame.maxX - badge * 0.8, y: avatarLayer.frame.maxY - badge * 0.8, width: badge, height: badge
        )
        let count = unread.bounds.size
        unread.frame = CGRect(
            x: avatarLayer.frame.maxX - count.width * 0.7, y: avatarLayer.frame.minY - 2,
            width: count.width, height: count.height
        )
        vibrantText.frame = bounds
        plainText.frame = bounds
        CATransaction.commit()
    }

    /// The unread count, or a dot, in the accent colour on the picture's
    /// corner, while the row has no room for it beside the name.
    private func drawUnread() {
        guard compact, let badge = content?.badge else {
            unread.isHidden = true
            return
        }
        let text: String? = switch badge {
        case .count(let count): count > 99 ? "99+" : "\(count)"
        case .dot: nil
        }
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let label = text.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: NSColor.white]) }
        let height: CGFloat = text == nil ? 10 : 16
        let width = max(height, (label?.size().width ?? 0) + 8)
        let scale = window?.backingScaleFactor ?? 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
                NSColor.controlAccentColor.setFill()
                let inner = rect.insetBy(dx: 1.5, dy: 1.5)
                NSBezierPath(roundedRect: inner, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
                if let label {
                    let size = label.size()
                    label.draw(at: NSPoint(x: (width - size.width) / 2, y: (height - size.height) / 2))
                }
                return true
            }
            unread.contents = image.layerContents(forContentsScale: scale)
        }
        unread.contentsScale = scale
        unread.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        unread.isHidden = false
        placeLayers(bounds.size)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for layer in [vibrantText, plainText] {
            layer.appearance = effectiveAppearance
            layer.setNeedsDisplay()
        }
        if let content { avatarLayer.setColor(seed: content.seed, appearance: effectiveAppearance) }
        if content?.disappearing == true { drawTimer() }
        drawUnread()
    }

    private static let timerSize = DisappearingBadgeArt.size(forAvatar: ChatCellMetrics.avatar)

    /// The timer badge (`DisappearingBadgeArt`), in this appearance's
    /// colours, on a disc of the window's background.
    private func drawTimer() {
        let size = Self.timerSize
        let scale = window?.backingScaleFactor ?? 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                DisappearingBadgeArt.draw(in: rect, background: .windowBackgroundColor)
                return true
            }
            // Drawn here, while this appearance's colours are current.
            timer.contents = image.layerContents(forContentsScale: scale)
        }
        timer.contentsScale = scale
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [avatarLayer, avatarLayer.glyph, avatarLayer.photo, vibrantText, plainText] { layer.contentsScale = scale }
        for layer in [avatarLayer.glyph, vibrantText, plainText] { layer.setNeedsDisplay() }
    }
}
