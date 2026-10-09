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

    private static let timerSize: CGFloat = 16

    /// The timer badge, in this appearance's colours: the accent on a disc
    /// of the window's background.
    private func drawTimer() {
        let size = Self.timerSize
        let scale = window?.backingScaleFactor ?? 2
        var image: NSImage?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(ovalIn: rect).fill()
                if let symbol = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)?
                    .withSymbolConfiguration(
                        NSImage.SymbolConfiguration(pointSize: size * 0.6, weight: .bold)
                            .applying(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor]))
                    ) {
                    symbol.draw(in: NSRect(
                        x: (size - symbol.size.width) / 2, y: (size - symbol.size.height) / 2,
                        width: symbol.size.width, height: symbol.size.height
                    ))
                }
                return true
            }
            // Drawn here, while this appearance's colours are current.
            timer.contents = image?.layerContents(forContentsScale: scale)
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

/// Archived or Locked Chats above the chats, drawn as the chats are: the
/// symbol and count vibrant, the name not.
final class FolderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarFolderCellDrawn")

    private let vibrant = RowLayerView(vibrant: true)
    private let plain = RowLayerView(vibrant: false)
    private let vibrantText = FolderRowLayer(pass: .vibrant)
    private let plainText = FolderRowLayer(pass: .plain)
    private(set) var folderID: String?
    private var open: () -> Void = {}
    /// Only the symbol, centred, in the collapsed sidebar.
    var compact = false

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        addSubview(vibrant)
        addSubview(plain)
        vibrant.layer?.addSublayer(vibrantText)
        plain.layer?.addSublayer(plainText)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func show(id: String, title: String, systemImage: String, count: Int?, open: @escaping () -> Void) {
        folderID = id
        self.open = open
        let content = FolderRowLayer.Content(
            title: compact ? "" : title, systemImage: systemImage,
            count: compact ? nil : count.flatMap { $0 > 0 ? $0 : nil }, centred: compact
        )
        guard content != plainText.content else { return }
        for layer in [vibrantText, plainText] {
            layer.content = content
            layer.setNeedsDisplay()
        }
        setAccessibilityLabel(content.count.map { "\(title), \($0)" } ?? title)
    }

    override func accessibilityPerformPress() -> Bool {
        open()
        return true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        vibrant.frame = bounds
        plain.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        vibrantText.frame = bounds
        plainText.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for layer in [vibrantText, plainText] {
            layer.appearance = effectiveAppearance
            layer.setNeedsDisplay()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        for layer in [vibrantText, plainText] {
            layer.contentsScale = window?.backingScaleFactor ?? 2
            layer.setNeedsDisplay()
        }
    }
}

/// Holds a cell's drawn layers; the vibrant one lets AppKit blend them with
/// the sidebar behind, as it does secondary labels.
final class RowLayerView: NSView {
    private let vibrant: Bool

    init(vibrant: Bool) {
        self.vibrant = vibrant
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var allowsVibrancy: Bool { vibrant }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Drawing

/// `ChatRow`'s geometry: a 40-point avatar, the text 12 points after it,
/// two lines 2 points apart, centred on the avatar.
enum ChatCellMetrics {
    static let avatar: CGFloat = Metrics.rowAvatar
    static let textLeading: CGFloat = Metrics.rowAvatar + Metrics.m
    static let lineSpacing: CGFloat = Metrics.xxs
    static let itemSpacing: CGFloat = Metrics.xs
    /// Where SwiftUI's stacks cut the title and the preview short, before
    /// the time and the marks (a `Spacer(minLength: 4)` and the spacing
    /// around it, as measured from its rows).
    static let titleGap: CGFloat = 8
    static let previewGap: CGFloat = 12
    static let badgeHeight: CGFloat = 18
    static let dot: CGFloat = 10
}

/// SwiftUI's text styles, as `ChatRow` uses them.
@MainActor
enum ChatCellFonts {
    static let title = NSFont.preferredFont(forTextStyle: .body)
    static let titleBold = NSFont.systemFont(ofSize: title.pointSize, weight: .semibold)
    static let time = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular
    )
    static let preview = NSFont.preferredFont(forTextStyle: .callout)
    static let badge = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .semibold
    )
    static let markSize = NSFont.preferredFont(forTextStyle: .caption2).pointSize

    /// The height SwiftUI gives a line of `font`, to the pixel.
    static func lineHeight(_ font: NSFont, scale: CGFloat = 2) -> CGFloat {
        ((font.ascender - font.descender + font.leading) * scale).rounded(.up) / scale
    }
}

/// Which of a row's two drawings: what SwiftUI draws in secondary and
/// tertiary styles (vibrant), or the rest.
enum DrawingPass: Sendable {
    case vibrant, plain
}

/// One pass of the row's text, marks and badge, drawn into a layer of its
/// own with 8-bit colour (rule 4 of PERFORMANCE.md).
nonisolated final class ChatRowLayer: CALayer {
    let pass: DrawingPass
    // Set by the cell and read in draw(in:); both on the main thread.
    nonisolated(unsafe) var content: ChatRowContent?
    nonisolated(unsafe) var emphasized = false
    nonisolated(unsafe) var appearance: NSAppearance?

    init(pass: DrawingPass) {
        self.pass = pass
        super.init()
        contentsFormat = .RGBA8Uint
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        pass = (layer as? ChatRowLayer)?.pass ?? .plain
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func action(forKey event: String) -> (any CAAction)? { nil }

    override func draw(in context: CGContext) {
        guard let content else { return }
        let size = bounds.size
        let emphasized = emphasized
        let pass = pass
        nonisolated(unsafe) let context = context
        nonisolated(unsafe) let appearance = appearance
        MainActor.assumeIsolated {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
                ChatRowDrawing(pass: pass, emphasized: emphasized).draw(content, size: size)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// Lays a row out the same way for both passes and paints what belongs to
/// the one asked for: everything else is laid out but left clear.
@MainActor
struct ChatRowDrawing {
    let pass: DrawingPass
    let emphasized: Bool
    private let colors: Colors

    init(pass: DrawingPass, emphasized: Bool) {
        self.pass = pass
        self.emphasized = emphasized
        colors = Colors(emphasized: emphasized)
    }

    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    struct Colors {
        var primary: NSColor
        var secondary: NSColor
        var tertiary: NSColor
        var accent: NSColor
        var red: NSColor
        var badge: NSColor
        var mutedBadge: NSColor
        var badgeText: NSColor
        var mutedBadgeText: NSColor

        init(emphasized: Bool) {
            if emphasized {
                primary = .alternateSelectedControlTextColor
                // As SwiftUI's secondary styles read on a selection.
                secondary = NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.72)
                tertiary = NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.5)
                accent = .alternateSelectedControlTextColor
                red = .alternateSelectedControlTextColor
                // A white capsule with the count in the accent colour, where
                // SwiftUI's accent capsule vanished into the selection.
                badge = .alternateSelectedControlTextColor
                mutedBadge = NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.45)
                badgeText = .controlAccentColor
                mutedBadgeText = .alternateSelectedControlTextColor
            } else {
                primary = .labelColor
                secondary = .secondaryLabelColor
                tertiary = .tertiaryLabelColor
                accent = .controlAccentColor
                // SwiftUI's red: in a sidebar's vibrant appearance AppKit's
                // system colours take other values than SwiftUI's.
                red = NSColor(Color.red)
                badge = .controlAccentColor
                mutedBadge = NSColor.secondaryLabelColor.withAlphaComponent(0.57 * NSColor.secondaryLabelColor.alphaComponent)
                badgeText = .white
                mutedBadgeText = .white
            }
        }
    }

    /// Whether something drawn in a secondary or tertiary style (`vibrant`)
    /// or not belongs to this pass. On a selection nothing is vibrant.
    private func paints(vibrant: Bool) -> Bool {
        (vibrant && !emphasized) == (pass == .vibrant)
    }

    /// `color` if this pass paints it, else clear, so text lays out alike.
    private func ink(_ color: NSColor, vibrant: Bool) -> NSColor {
        paints(vibrant: vibrant) ? color : .clear
    }

    func draw(_ content: ChatRowContent, size: CGSize) {
        let left = ChatCellMetrics.textLeading
        let right = size.width
        let titleFont = content.bold ? ChatCellFonts.titleBold : ChatCellFonts.title
        // The text style's line height, which its bold weight keeps in
        // SwiftUI (the bold system font alone has no leading).
        let firstLine = ChatCellFonts.lineHeight(ChatCellFonts.title)
        let secondLine = max(
            ChatCellFonts.lineHeight(ChatCellFonts.preview),
            content.badge == nil ? markHeight(content) : content.badge == .dot ? ChatCellMetrics.dot : ChatCellMetrics.badgeHeight
        )
        let top = (size.height - firstLine - ChatCellMetrics.lineSpacing - secondLine) / 2

        // First line: the title, and the time on its baseline.
        let baseline = top + titleFont.ascender
        let time = NSAttributedString(string: content.time, attributes: [
            .font: ChatCellFonts.time,
            .foregroundColor: content.timeAccented
                ? ink(colors.accent, vibrant: false) : ink(colors.secondary, vibrant: true),
        ])
        let timeWidth = ceil(time.size().width)
        time.draw(at: CGPoint(x: right - timeWidth, y: baseline - ChatCellFonts.time.ascender))
        if paints(vibrant: false) {
            let title = NSAttributedString(string: content.title, attributes: [
                .font: titleFont, .foregroundColor: colors.primary, .paragraphStyle: Self.truncating,
            ])
            let titleWidth = max(0, right - timeWidth - ChatCellMetrics.titleGap - left)
            title.draw(
                with: CGRect(x: left, y: top, width: titleWidth, height: firstLine),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
        }

        // Second line: the preview, then the marks and the badge at the end.
        let middle = top + firstLine + ChatCellMetrics.lineSpacing + secondLine / 2
        var trailing = right
        if let badge = content.badge {
            trailing = drawBadge(badge, muted: content.muted, right: trailing, middle: middle) - ChatCellMetrics.itemSpacing
        }
        if content.pinned, let pin = Self.symbol("pin.fill", size: ChatCellFonts.markSize, weight: .regular, color: colors.tertiary) {
            trailing = drawImage(pin, vibrant: true, right: trailing, middle: middle) - ChatCellMetrics.itemSpacing
        }
        if content.muted, let bell = Self.symbol("bell.slash.fill", size: ChatCellFonts.markSize, weight: .regular, color: colors.tertiary) {
            trailing = drawImage(bell, vibrant: true, right: trailing, middle: middle) - ChatCellMetrics.itemSpacing
        }
        drawPreview(content.preview, left: left, right: trailing - ChatCellMetrics.previewGap, middle: middle)
    }

    /// The tallest of the muted and pinned marks, for a row without a badge.
    private func markHeight(_ content: ChatRowContent) -> CGFloat {
        var height: CGFloat = 0
        if content.muted, let bell = Self.symbol("bell.slash.fill", size: ChatCellFonts.markSize, weight: .regular, color: .labelColor) {
            height = max(height, bell.size.height)
        }
        if content.pinned, let pin = Self.symbol("pin.fill", size: ChatCellFonts.markSize, weight: .regular, color: .labelColor) {
            height = max(height, pin.size.height)
        }
        return height
    }

    private func drawPreview(_ preview: ChatRowContent.Preview, left: CGFloat, right: CGFloat, middle: CGFloat) {
        let font = ChatCellFonts.preview
        let line = NSMutableAttributedString()
        var x = left
        switch preview {
        case .typing(let text):
            line.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink(colors.accent, vibrant: false)]))
        case .draft(let text):
            line.append(NSAttributedString(
                string: String(localized: "Draft: "), attributes: [.font: font, .foregroundColor: ink(colors.red, vibrant: false)]
            ))
            line.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink(colors.secondary, vibrant: true)]))
        case .message(let text, let ticks):
            if let ticks {
                x = drawTicks(ticks, left: x, middle: middle) + Metrics.xxs
            }
            line.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink(colors.secondary, vibrant: true)]))
        case .nothing:
            return
        }
        let whole = NSRange(location: 0, length: line.length)
        line.addAttribute(.paragraphStyle, value: Self.truncating, range: whole)
        // One line, as SwiftUI's `lineLimit(1)`: line breaks read as spaces.
        line.mutableString.replaceOccurrences(of: "\n", with: " ", options: [], range: whole)
        let height = ChatCellFonts.lineHeight(font)
        line.draw(
            with: CGRect(x: x, y: middle - height / 2, width: max(0, right - x), height: height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }

    /// `DeliveryTicks`: a clock, one tick, two ticks (tinted when read), or
    /// a red mark. Returns where the text after them starts.
    private func drawTicks(_ state: DeliveryTicks.State, left: CGFloat, middle: CGFloat) -> CGFloat {
        let (name, color, vibrant): (String, NSColor, Bool) = switch state {
        case .pending: ("clock", colors.secondary, true)
        case .sent, .delivered: ("checkmark", colors.secondary, true)
        case .read: ("checkmark", colors.accent, false)
        case .failed: ("exclamationmark.circle.fill", colors.red, false)
        }
        guard let image = Self.symbol(name, size: 9, weight: .bold, color: color) else { return left }
        let end = drawImage(image, vibrant: vibrant, left: left, middle: middle)
        guard state == .delivered || state == .read else { return end }
        // The second tick 4 points on; the pair takes 4 points more than one.
        return drawImage(image, vibrant: vibrant, left: left + 4, middle: middle)
    }

    /// The unread count in its capsule, or the dot. A muted chat's capsule
    /// is in a secondary style. Returns its left edge.
    private func drawBadge(_ badge: ChatRowContent.Badge, muted: Bool, right: CGFloat, middle: CGFloat) -> CGFloat {
        let fill = muted ? colors.mutedBadge : colors.badge
        switch badge {
        case .dot:
            let size = ChatCellMetrics.dot
            if paints(vibrant: muted) {
                fill.setFill()
                NSBezierPath(ovalIn: CGRect(x: right - size, y: middle - size / 2, width: size, height: size)).fill()
            }
            return right - size
        case .count(let count):
            let text = NSAttributedString(string: count > 999 ? "999+" : "\(count)", attributes: [
                .font: ChatCellFonts.badge, .foregroundColor: muted ? colors.mutedBadgeText : colors.badgeText,
            ])
            let textSize = text.size()
            let height = ChatCellMetrics.badgeHeight
            let width = max(height, ceil(textSize.width) + 2 * 6)
            let rect = CGRect(x: right - width, y: middle - height / 2, width: width, height: height)
            if paints(vibrant: muted) {
                fill.setFill()
                NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
            }
            if paints(vibrant: false) {
                text.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            }
            return rect.minX
        }
    }

    private func drawImage(_ image: NSImage, vibrant: Bool, right: CGFloat, middle: CGFloat) -> CGFloat {
        let size = image.size
        if paints(vibrant: vibrant) {
            image.draw(in: CGRect(x: right - size.width, y: Self.pixel(middle - size.height / 2), width: size.width, height: size.height))
        }
        return right - size.width
    }

    private func drawImage(_ image: NSImage, vibrant: Bool, left: CGFloat, middle: CGFloat) -> CGFloat {
        let size = image.size
        if paints(vibrant: vibrant) {
            image.draw(in: CGRect(x: left, y: Self.pixel(middle - size.height / 2), width: size.width, height: size.height))
        }
        return left + size.width
    }

    /// On a pixel of a Retina display, as SwiftUI places images.
    private static func pixel(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }

    private static var symbols: [String: NSImage] = [:]

    /// An SF Symbol in one colour, as SwiftUI's foreground style draws it
    /// (monochrome: an "!" in a filled circle is cut out of it), made once
    /// per name, size and colour as resolved now (dynamic colours differ in
    /// light and dark).
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let key = "\(name)|\(size)|\(weight.rawValue)|\(resolved.redComponent),\(resolved.greenComponent),\(resolved.blueComponent),\(resolved.alphaComponent)"
        if let cached = symbols[key] { return cached }
        guard let shape = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight)) else { return nil }
        let image = NSImage(size: shape.size, flipped: false) { rect in
            shape.draw(in: rect)
            resolved.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        if symbols.count > 128 { symbols.removeAll() }
        symbols[key] = image
        return image
    }
}

/// A round placeholder (initials or a symbol on the chat's colour, as
/// `AvatarView` draws it) with the photo over it once loaded.
///
/// The colour is SwiftUI's `Color.gradient` as measured from its output: a
/// little lighter at the top (about a quarter of the way to white), the
/// colour itself from seven tenths down. Core Animation draws it, with
/// SwiftUI's colours resolved for the cell's appearance: in a sidebar's
/// vibrant appearance AppKit's system colours take other values.
nonisolated final class AvatarLayer: CAGradientLayer {
    let glyph = AvatarGlyphLayer()
    let photo = CALayer()

    override init() {
        super.init()
        masksToBounds = true
        locations = [0, 0.7, 1]
        glyph.contentsFormat = .RGBA8Uint
        glyph.needsDisplayOnBoundsChange = true
        photo.contentsGravity = .resizeAspectFill
        for layer in [self, glyph, photo] as [CALayer] {
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "cornerRadius": NSNull()]
        }
        addSublayer(glyph)
        addSublayer(photo)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSublayers() {
        super.layoutSublayers()
        cornerRadius = bounds.width / 2
        glyph.frame = bounds
        photo.frame = bounds
    }

    /// The chat's colour, for `appearance`.
    @MainActor
    func setColor(seed: String, appearance: NSAppearance) {
        appearance.performAsCurrentDrawingAppearance {
            let color = NSColor(Palette.sender(seed)).usingColorSpace(.extendedSRGB) ?? NSColor(Palette.sender(seed))
            let lighter: [CGFloat] = [color.redComponent, color.greenComponent, color.blueComponent].map { $0 + 0.27 * (1 - $0) }
            let top = NSColor(colorSpace: .extendedSRGB, components: lighter + [1], count: 4)
            colors = [top.cgColor, color.cgColor, color.cgColor]
        }
    }

    func setPhoto(_ image: NSImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photo.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        CATransaction.commit()
    }
}

/// The initials or symbol on a placeholder, in white.
nonisolated final class AvatarGlyphLayer: CALayer {
    nonisolated(unsafe) var placeholder: ChatRowContent.Placeholder?

    override func action(forKey event: String) -> (any CAAction)? { nil }

    override func draw(in context: CGContext) {
        guard let placeholder else { return }
        let rect = bounds
        nonisolated(unsafe) let context = context
        MainActor.assumeIsolated {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            Self.draw(placeholder, in: rect)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    @MainActor
    private static func draw(_ placeholder: ChatRowContent.Placeholder, in rect: CGRect) {
        switch placeholder {
        case .initials(let text):
            let font = NSFont.systemFont(ofSize: rect.width * 0.38, weight: .semibold)
            let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: font.pointSize) } ?? font
            let string = NSAttributedString(string: text, attributes: [.font: rounded, .foregroundColor: NSColor.white])
            let size = string.size()
            string.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        case .symbol(let name):
            guard let image = ChatRowDrawing.symbol(name, size: rect.width * 0.42, weight: .medium, color: .white) else { return }
            let size = image.size
            image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        }
    }
}

/// `FolderRow`: the folder's symbol where a chat's avatar is, its name, and
/// a count at the end; the symbol and count in a secondary style.
nonisolated final class FolderRowLayer: CALayer {
    struct Content: Equatable {
        var title: String
        var systemImage: String
        var count: Int?
        /// In the middle of the row, in the collapsed sidebar.
        var centred = false
    }

    let pass: DrawingPass
    nonisolated(unsafe) var content: Content?
    nonisolated(unsafe) var appearance: NSAppearance?

    init(pass: DrawingPass) {
        self.pass = pass
        super.init()
        contentsFormat = .RGBA8Uint
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        pass = (layer as? FolderRowLayer)?.pass ?? .plain
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func action(forKey event: String) -> (any CAAction)? { nil }

    override func draw(in context: CGContext) {
        guard let content else { return }
        let size = bounds.size
        let pass = pass
        nonisolated(unsafe) let context = context
        nonisolated(unsafe) let appearance = appearance
        MainActor.assumeIsolated {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
                Self.draw(content, size: size, pass: pass)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    @MainActor
    private static func draw(_ content: Content, size: CGSize, pass: DrawingPass) {
        let middle = size.height / 2
        let body = ChatCellFonts.title
        if pass == .vibrant,
           let image = ChatRowDrawing.symbol(content.systemImage, size: body.pointSize, weight: .regular, color: .secondaryLabelColor) {
            let imageSize = image.size
            let column = content.centred ? size.width : ChatCellMetrics.avatar
            image.draw(in: CGRect(
                x: (column - imageSize.width) / 2, y: middle - imageSize.height / 2,
                width: imageSize.width, height: imageSize.height
            ))
        }
        var right = size.width
        if let count = content.count {
            let text = NSAttributedString(string: "\(count)", attributes: [
                .font: ChatCellFonts.time, .foregroundColor: pass == .vibrant ? NSColor.secondaryLabelColor : .clear,
            ])
            let textSize = text.size()
            text.draw(at: CGPoint(x: right - ceil(textSize.width), y: middle - textSize.height / 2))
            right -= ceil(textSize.width) + Metrics.s
        }
        guard pass == .plain else { return }
        let title = NSAttributedString(string: content.title, attributes: [.font: body, .foregroundColor: NSColor.labelColor])
        let height = ChatCellFonts.lineHeight(body)
        title.draw(
            with: CGRect(x: ChatCellMetrics.textLeading, y: middle - height / 2, width: max(0, right - ChatCellMetrics.textLeading), height: height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }
}
