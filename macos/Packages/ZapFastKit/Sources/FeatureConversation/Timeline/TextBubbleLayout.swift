import AppKit
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Everything a plain text message's row shows, resolved on the main actor
/// (names come from the stores) so the layout can run anywhere.
nonisolated struct TextBubbleSource: Equatable, Sendable {
    struct Quote: Equatable, Sendable {
        var name: String
        var summary: String
        var senderID: String
    }

    var id: String
    var fromMe: Bool
    var startsRun: Bool
    var text: String
    /// Up to three emoji and nothing else: drawn large, and without a
    /// bubble unless it quotes something.
    var emojiOnly: Bool
    var mentions: [MentionInfo]
    /// Display names for the mentioned ids.
    var mentionNames: [String: String]
    /// Shown on the first message of a run in a group.
    var senderName: String?
    var senderID: String
    var forwarded: Bool
    var quote: Quote?
    var edited: Bool
    var timestamp: Int64
    var status: DeliveryState
    var reactions: [ReactionInfo]
    /// The chat's theme and text size.
    var colors: BubbleColors
}

/// Text drawn at a place, in the coordinates of whatever holds it.
nonisolated struct TextPiece: @unchecked Sendable {
    /// Immutable once built.
    let string: NSAttributedString
    let rect: CGRect

    func draw(options: NSString.DrawingOptions = TimelineText.drawingOptions) {
        string.draw(with: rect, options: options, context: nil)
    }
}

/// A plain text message's row, measured for one bubble width. Immutable,
/// so it is built off the main actor and read on it.
nonisolated final class TextBubbleLayout: @unchecked Sendable {
    struct QuoteLayout {
        var rect: CGRect
        var bar: CGRect
        var barColor: NSColor
        var name: TextPiece
        var summary: TextPiece
    }

    struct Footer {
        var rect: CGRect
        var edited: TextPiece?
        var time: TextPiece
        /// Where the ticks go, for outgoing messages.
        var ticks: CGRect?
        var state: DeliveryState
        var tint: NSColor
        var secondary: NSColor
        /// The capsule behind the footer of a message without a bubble.
        var capsule: CGRect?
    }

    struct Pill {
        var rect: CGRect
        var emoji: TextPiece
        var count: TextPiece?
        var mine: Bool
    }

    let widthLimit: CGFloat
    let fromMe: Bool
    let startsRun: Bool
    /// No bubble behind it: large emoji alone.
    let bare: Bool
    let bubbleSize: CGSize
    /// Parts, in the bubble's coordinates (top left origin).
    let name: TextPiece?
    let forwarded: TextPiece?
    let forwardedIcon: CGRect?
    let quote: QuoteLayout?
    /// The text with room for the footer at its end. `bodyLength` is where
    /// the visible text stops.
    let body: TextPiece
    let bodyLength: Int
    let footer: Footer
    let textColor: NSColor
    let linkColor: NSColor
    /// Behind the bubble; nil without one.
    let bubbleColor: NSColor?
    /// Over a wallpaper bubbles lift a little, as on the phone.
    let lifted: Bool
    /// The chat's accent, for the highlight of a message jumped to.
    let accent: NSColor
    /// Reaction pills, in their own strip's coordinates.
    let pills: [Pill]
    let pillsSize: CGSize
    let rowHeight: CGFloat
    let accessibilityLabel: String

    init(
        widthLimit: CGFloat, fromMe: Bool, startsRun: Bool, bare: Bool, bubbleSize: CGSize,
        name: TextPiece?, forwarded: TextPiece?, forwardedIcon: CGRect?, quote: QuoteLayout?,
        body: TextPiece, bodyLength: Int, footer: Footer, textColor: NSColor, linkColor: NSColor,
        bubbleColor: NSColor?, lifted: Bool, accent: NSColor,
        pills: [Pill], pillsSize: CGSize, accessibilityLabel: String
    ) {
        self.widthLimit = widthLimit
        self.fromMe = fromMe
        self.startsRun = startsRun
        self.bare = bare
        self.bubbleSize = bubbleSize
        self.name = name
        self.forwarded = forwarded
        self.forwardedIcon = forwardedIcon
        self.quote = quote
        self.body = body
        self.bodyLength = bodyLength
        self.footer = footer
        self.textColor = textColor
        self.linkColor = linkColor
        self.bubbleColor = bubbleColor
        self.lifted = lifted
        self.accent = accent
        self.pills = pills
        self.pillsSize = pillsSize
        self.accessibilityLabel = accessibilityLabel
        let reactions = pills.isEmpty ? 0 : pillsSize.height - TimelineGeometry.reactionOverlap
        rowHeight = TimelineGeometry.topInset(startsRun: startsRun) + bubbleSize.height + reactions
            + TimelineGeometry.rowBottom
    }

    /// The bubble's frame in a row of the given width.
    func bubbleFrame(rowWidth: CGFloat) -> CGRect {
        let x = fromMe ? rowWidth - Metrics.l - bubbleSize.width : Metrics.l
        return CGRect(origin: CGPoint(x: x, y: TimelineGeometry.topInset(startsRun: startsRun)), size: bubbleSize)
    }

    /// The reaction strip's frame, overlapping the bubble's bottom edge.
    func pillsFrame(rowWidth: CGFloat) -> CGRect {
        let bubble = bubbleFrame(rowWidth: rowWidth)
        let inset = TimelineGeometry.reactionInset
        let x = fromMe ? bubble.maxX - inset - pillsSize.width : bubble.minX + inset
        return CGRect(x: x, y: bubble.maxY - TimelineGeometry.reactionOverlap, width: pillsSize.width, height: pillsSize.height)
    }
}

/// The row geometry `MessageRow` and `MessageBubble` use, in numbers.
nonisolated enum TimelineGeometry {
    /// Room kept beside a bubble (the row's `Spacer(minLength: 72)`).
    static let besideBubble: CGFloat = 72
    static let bubblePadding = CGSize(width: Metrics.m, height: Metrics.s)
    static let partSpacing = Metrics.xs
    static let rowBottom = Metrics.xxs
    static let reactionOverlap = Metrics.xs
    static let reactionInset = Metrics.s
    static let footerSpacing = Metrics.xs
    /// The footer hangs this far below the text's last line.
    static let footerDrop: CGFloat = 2
    static let ticksWidth: CGFloat = 14
    static let quotePadding = Metrics.s
    static let quoteBarWidth: CGFloat = 3
    static let forwardedIconWidth: CGFloat = 13

    static func topInset(startsRun: Bool) -> CGFloat {
        startsRun ? Metrics.s : Metrics.xxs
    }

    /// The widest a bubble may be in a timeline this wide. Rows depend on
    /// the width only through this, so resizing a wide window changes
    /// nothing.
    static func bubbleWidthLimit(rowWidth: CGFloat) -> CGFloat {
        max(120, min(Metrics.bubbleMaxWidth, (rowWidth - Metrics.l * 2 - besideBubble).rounded(.down)))
    }
}

/// Fonts and text building shared by layout and drawing.
nonisolated enum TimelineText {
    static let drawingOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    /// Message text at the chat's text size, as `BodyText` sets it.
    struct BodyFonts: @unchecked Sendable {
        let body: NSFont
        let bold: NSFont
        let italic: NSFont
        let code: NSFont
        /// A message of emoji alone.
        let largeEmoji: NSFont
        let dotWidth: CGFloat

        init(scale: Double) {
            body = NSFont.systemFont(ofSize: NSFont.systemFontSize * scale)
            bold = TimelineText.styled(body, .bold)
            italic = TimelineText.styled(body, .italic)
            code = NSFont.monospacedSystemFont(ofSize: body.pointSize, weight: .regular)
            largeEmoji = NSFont.systemFont(ofSize: 40 * scale)
            dotWidth = TimelineText.size(NSAttributedString(string: ".", attributes: [.font: body])).width
        }
    }

    private static let fontLock = NSLock()
    nonisolated(unsafe) private static var fontsByScale: [Double: BodyFonts] = [:]

    /// Made once per text size; layouts run on many threads at once.
    static func bodyFonts(scale: Double) -> BodyFonts {
        fontLock.lock()
        defer { fontLock.unlock() }
        if let fonts = fontsByScale[scale] { return fonts }
        let fonts = BodyFonts(scale: scale)
        fontsByScale[scale] = fonts
        return fonts
    }

    nonisolated(unsafe) static let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    nonisolated(unsafe) static let caption = NSFont.preferredFont(forTextStyle: .caption1)
    nonisolated(unsafe) static let captionSemibold = NSFont.systemFont(ofSize: caption.pointSize, weight: .semibold)
    nonisolated(unsafe) static let captionMedium = NSFont.systemFont(ofSize: caption.pointSize, weight: .medium)
    nonisolated(unsafe) static let captionItalic = styled(caption, .italic)
    nonisolated(unsafe) static let caption2 = NSFont.preferredFont(forTextStyle: .caption2)
    nonisolated(unsafe) static let caption2Digits = NSFont.monospacedDigitSystemFont(ofSize: caption2.pointSize, weight: .regular)
    nonisolated(unsafe) static let callout = NSFont.preferredFont(forTextStyle: .callout)
    fileprivate static func styled(_ font: NSFont, _ trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// Size of text laid out in `width`, rounded up to whole points.
    static func size(_ string: NSAttributedString, width: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        let bounds = string.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: drawingOptions,
            context: nil
        )
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    static func line(_ text: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
    }

    /// Height of `lines` lines of a font, as the drawing measures them.
    static func height(ofLines lines: Int, _ font: NSFont) -> CGFloat {
        let sample = Array(repeating: "Ag", count: lines).joined(separator: "\n")
        return size(NSAttributedString(string: sample, attributes: [.font: font])).height
    }

    /// WhatsApp markup, links and mentions, in AppKit attributes.
    static func body(_ source: TextBubbleSource, fonts: BodyFonts, color: NSColor, link: NSColor) -> NSMutableAttributedString {
        if source.emojiOnly {
            return NSMutableAttributedString(string: source.text, attributes: [.font: fonts.largeEmoji, .foregroundColor: color])
        }
        let markup = WhatsAppMarkup.attributed(
            source.text,
            mentions: source.mentions,
            name: { source.mentionNames[$0] ?? $0 }
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let output = NSMutableAttributedString()
        for run in markup.runs {
            let text = String(markup[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            let font: NSFont = if intent.contains(.code) {
                fonts.code
            } else if intent.contains(.stronglyEmphasized) {
                fonts.bold
            } else if intent.contains(.emphasized) {
                fonts.italic
            } else {
                fonts.body
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let url = run.link {
                attributes[.link] = url
                attributes[.foregroundColor] = link
            }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }
        return output
    }

    /// Clear text that keeps `width` free at the end of the last line: a
    /// visible glyph, since trailing whitespace would hang past the edge and
    /// let the footer cover the last word. The word joiner keeps it with
    /// that word, so when the footer does not fit they wrap together. The
    /// space rides on the middle glyph: kerning after a line's last glyph
    /// counts for the text view but not for string drawing, and the two
    /// must break lines alike.
    static func reserve(width: CGFloat, fonts: BodyFonts) -> NSAttributedString {
        let clear: [NSAttributedString.Key: Any] = [.font: fonts.body, .foregroundColor: NSColor.clear]
        let reserve = NSMutableAttributedString(string: "\u{2060}", attributes: clear)
        var spaced = clear
        spaced[.kern] = max(0, width - fonts.dotWidth * 2)
        reserve.append(NSAttributedString(string: ".", attributes: spaced))
        reserve.append(NSAttributedString(string: ".", attributes: clear))
        return reserve
    }

    /// Characters `reserve(width:)` adds after the text.
    static let reserveLength = 3
}
