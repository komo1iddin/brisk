/// What a chat row looks like: its metrics, its fonts, and the drawing of
/// one row into a layer.

import AppKit
import Observation
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

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
