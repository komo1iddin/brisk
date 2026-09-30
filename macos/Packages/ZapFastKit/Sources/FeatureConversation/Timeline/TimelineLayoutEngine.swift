import AppKit
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Measures plain text messages the way `TextBubbleCell` draws them, with
/// the same strings and the same text system, off the main actor. A
/// timeline's worth runs in parallel: 10,000 messages take a fraction of a
/// second on Apple silicon, which the main actor never waits for.
nonisolated enum TimelineLayoutEngine {
    static func layouts(for sources: [TextBubbleSource], widthLimit: CGFloat) -> [TextBubbleLayout] {
        guard sources.count > 32 else {
            return sources.map { layout(for: $0, widthLimit: widthLimit) }
        }
        let chunkSize = 64
        let chunkCount = (sources.count + chunkSize - 1) / chunkSize
        let results = UnsafeMutableBufferPointer<TextBubbleLayout?>.allocate(capacity: sources.count)
        results.initialize(repeating: nil)
        defer { results.deallocate() }
        // Each chunk writes its own range, so sharing the buffer is race-free.
        nonisolated(unsafe) let base = results.baseAddress!
        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
            let range = (chunk * chunkSize)..<min((chunk + 1) * chunkSize, sources.count)
            for index in range {
                base[index] = layout(for: sources[index], widthLimit: widthLimit)
            }
        }
        return results.map { $0! }
    }

    static func layout(for source: TextBubbleSource, widthLimit: CGFloat) -> TextBubbleLayout {
        typealias G = TimelineGeometry
        typealias T = TimelineText
        let fromMe = source.fromMe
        // Emoji alone float without a bubble, in the ordinary text colours.
        let bare = source.emojiOnly && source.quote == nil
        let onAccent = fromMe && !bare
        let colors = source.colors
        let fonts = T.bodyFonts(scale: colors.textScale)
        let textColor: NSColor = onAccent ? colors.outgoingText : .labelColor
        let secondary: NSColor = onAccent ? colors.outgoingText.withAlphaComponent(0.7) : .secondaryLabelColor
        let linkColor: NSColor = onAccent ? colors.outgoingText : colors.accent
        let padding = bare ? .zero : G.bubblePadding
        let contentLimit = widthLimit - padding.width * 2
        // The time tucks into the last line of text; after large emoji it
        // is a line of its own on the trailing edge.
        let inlineFooter = !source.emojiOnly
        let capsuleInset: CGFloat = bare ? Metrics.s : 0

        // Footer: edited, time, ticks.
        let edited = source.edited ? T.line(String(localized: "Edited"), T.caption2, secondary) : nil
        let time = T.line(DateText.date(source.timestamp).formatted(date: .omitted, time: .shortened), T.caption2Digits, secondary)
        let editedSize = edited.map { T.size($0) } ?? .zero
        let timeSize = T.size(time)
        let footerWidth = (edited == nil ? 0 : editedSize.width + G.footerSpacing) + timeSize.width
            + (fromMe ? G.footerSpacing + G.ticksWidth : 0)
        let footerHeight = max(timeSize.height, editedSize.height)

        // Parts and how wide each would like to be.
        let name = source.senderName.map { T.line($0, T.captionSemibold, AppKitPalette.sender(source.senderID)) }
        let forwarded = source.forwarded ? T.line(String(localized: "Forwarded"), T.captionItalic, secondary) : nil
        let quoteName = source.quote.map {
            T.line($0.name, T.captionSemibold, onAccent ? colors.outgoingText : AppKitPalette.sender($0.senderID))
        }
        let quoteSummary = source.quote.map { quote -> NSAttributedString in
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            return NSAttributedString(string: quote.summary, attributes: [
                .font: T.callout, .foregroundColor: textColor.withAlphaComponent(0.85), .paragraphStyle: paragraph,
            ])
        }
        let body = T.body(source, fonts: fonts, color: textColor, link: linkColor)
        let bodyLength = body.length
        if inlineFooter { body.append(T.reserve(width: footerWidth + G.footerSpacing * 2, fonts: fonts)) }

        let quoteChrome = G.quotePadding * 3 + G.quoteBarWidth
        var ideal = T.size(body).width
        if !inlineFooter { ideal = max(ideal, footerWidth + capsuleInset * 2) }
        if let name { ideal = max(ideal, T.size(name).width) }
        if let forwarded { ideal = max(ideal, G.forwardedIconWidth + G.footerSpacing + T.size(forwarded).width) }
        if let quoteName, let quoteSummary {
            ideal = max(ideal, quoteChrome + max(T.size(quoteName).width, T.size(quoteSummary).width))
        }
        let width = min(ceil(ideal), contentLimit)

        // Top to bottom, in the bubble's coordinates.
        let left = padding.width
        var y = padding.height
        func advance(_ height: CGFloat) -> CGFloat {
            defer { y += height + G.partSpacing }
            return y
        }

        let namePiece = name.map { string in
            let height = T.size(string).height
            return TextPiece(string: string, rect: CGRect(x: left, y: advance(height), width: width, height: height))
        }

        var forwardedIcon: CGRect?
        let forwardedPiece = forwarded.map { string in
            let height = T.size(string).height
            let top = advance(height)
            forwardedIcon = CGRect(x: left, y: top, width: G.forwardedIconWidth, height: height)
            let x = left + G.forwardedIconWidth + G.footerSpacing
            return TextPiece(string: string, rect: CGRect(x: x, y: top, width: width - (x - left), height: height))
        }

        var quote: TextBubbleLayout.QuoteLayout?
        if let source = source.quote, let quoteName, let quoteSummary {
            let textWidth = max(1, width - quoteChrome)
            let nameHeight = T.height(ofLines: 1, T.captionSemibold)
            let summaryHeight = min(T.size(quoteSummary, width: textWidth).height, twoCalloutLines)
            let height = G.quotePadding * 2 + nameHeight + 1 + summaryHeight
            let rect = CGRect(x: left, y: advance(height), width: width, height: height)
            let textX = rect.minX + G.quotePadding * 2 + G.quoteBarWidth
            quote = .init(
                rect: rect,
                bar: CGRect(x: rect.minX + G.quotePadding, y: rect.minY + G.quotePadding, width: G.quoteBarWidth, height: height - G.quotePadding * 2),
                barColor: onAccent ? colors.outgoingText : AppKitPalette.sender(source.senderID),
                name: TextPiece(string: quoteName, rect: CGRect(x: textX, y: rect.minY + G.quotePadding, width: textWidth, height: nameHeight)),
                summary: TextPiece(string: quoteSummary, rect: CGRect(
                    x: textX, y: rect.minY + G.quotePadding + nameHeight + 1, width: textWidth, height: summaryHeight
                ))
            )
        }

        let bodyHeight = T.size(body, width: width).height
        let bodyRect = CGRect(x: left, y: advance(bodyHeight), width: width, height: bodyHeight)
        let footerRect: CGRect
        var capsule: CGRect?
        if inlineFooter {
            footerRect = CGRect(
                x: left + width - footerWidth,
                y: bodyRect.maxY + G.footerDrop - footerHeight,
                width: footerWidth,
                height: footerHeight
            )
        } else {
            let top = advance(footerHeight)
            footerRect = CGRect(x: left + width - capsuleInset - footerWidth, y: top, width: footerWidth, height: footerHeight)
            if bare { capsule = footerRect.insetBy(dx: -capsuleInset, dy: 0) }
        }
        let bubbleHeight = y - G.partSpacing + padding.height
        var x = footerRect.minX
        let editedPiece = edited.map { string in
            defer { x += editedSize.width + G.footerSpacing }
            return TextPiece(string: string, rect: CGRect(x: x, y: footerRect.maxY - editedSize.height, width: editedSize.width, height: editedSize.height))
        }
        let timePiece = TextPiece(string: time, rect: CGRect(x: x, y: footerRect.maxY - timeSize.height, width: timeSize.width, height: timeSize.height))
        let ticks = fromMe
            ? CGRect(x: footerRect.maxX - G.ticksWidth, y: footerRect.minY, width: G.ticksWidth, height: footerHeight)
            : nil

        let (pills, pillsSize) = reactionPills(source.reactions)

        return TextBubbleLayout(
            widthLimit: widthLimit,
            fromMe: fromMe,
            startsRun: source.startsRun,
            bare: bare,
            bubbleSize: CGSize(width: width + padding.width * 2, height: ceil(bubbleHeight)),
            name: namePiece,
            forwarded: forwardedPiece,
            forwardedIcon: forwardedIcon,
            quote: quote,
            body: TextPiece(string: body, rect: bodyRect),
            bodyLength: bodyLength,
            footer: .init(
                rect: footerRect, edited: editedPiece, time: timePiece, ticks: ticks, state: source.status,
                tint: bare ? colors.accent : colors.readTicks, secondary: secondary,
                capsule: capsule
            ),
            textColor: textColor,
            linkColor: linkColor,
            bubbleColor: bare ? nil : (fromMe ? colors.outgoing : colors.incoming),
            lifted: colors.hasWallpaper,
            accent: colors.accent,
            pills: pills,
            pillsSize: pillsSize,
            accessibilityLabel: accessibilityLabel(source, time: time.string)
        )
    }

    private static let twoCalloutLines = TimelineText.height(ofLines: 2, TimelineText.callout)

    /// Reactions grouped by emoji, most chosen first, as `ReactionPills`.
    private static func reactionPills(_ reactions: [ReactionInfo]) -> ([TextBubbleLayout.Pill], CGSize) {
        guard !reactions.isEmpty else { return ([], .zero) }
        let groups = Dictionary(grouping: reactions, by: \.emoji)
            .map { (emoji: $0.key, count: $0.value.count, mine: $0.value.contains(where: \.fromMe)) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.emoji < $1.emoji }
        let padding = CGSize(width: 6, height: 2)
        var pills: [TextBubbleLayout.Pill] = []
        var x: CGFloat = 0
        var height: CGFloat = 0
        for group in groups {
            let emoji = NSAttributedString(string: group.emoji, attributes: [.font: TimelineText.callout])
            let count = group.count > 1
                ? TimelineText.line("\(group.count)", TimelineText.caption2Digits, .secondaryLabelColor)
                : nil
            let emojiSize = TimelineText.size(emoji)
            let countSize = count.map { TimelineText.size($0) } ?? .zero
            let inner = CGSize(
                width: emojiSize.width + (count == nil ? 0 : 2 + countSize.width),
                height: max(emojiSize.height, countSize.height)
            )
            let rect = CGRect(x: x, y: 0, width: inner.width + padding.width * 2, height: inner.height + padding.height * 2)
            pills.append(.init(
                rect: rect,
                emoji: TextPiece(string: emoji, rect: CGRect(
                    x: rect.minX + padding.width, y: (rect.height - emojiSize.height) / 2,
                    width: emojiSize.width, height: emojiSize.height
                )),
                count: count.map { TextPiece(string: $0, rect: CGRect(
                    x: rect.minX + padding.width + emojiSize.width + 2, y: (rect.height - countSize.height) / 2,
                    width: countSize.width, height: countSize.height
                )) },
                mine: group.mine
            ))
            x = rect.maxX + Metrics.xxs
            height = max(height, rect.height)
        }
        return (pills, CGSize(width: x - Metrics.xxs, height: height))
    }

    private static func accessibilityLabel(_ source: TextBubbleSource, time: String) -> String {
        var parts: [String] = []
        if source.fromMe {
            parts.append(String(localized: "You"))
        } else if let name = source.senderName {
            parts.append(name)
        }
        if source.forwarded { parts.append(String(localized: "Forwarded")) }
        if let quote = source.quote {
            parts.append(String(localized: "Replying to \(quote.name): \(quote.summary)"))
        }
        parts.append(source.text)
        if source.edited { parts.append(String(localized: "Edited")) }
        parts.append(time)
        return parts.joined(separator: ", ")
    }
}
