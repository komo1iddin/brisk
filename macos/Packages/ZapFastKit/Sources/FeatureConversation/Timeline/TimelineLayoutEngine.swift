import AppKit
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Measures drawn messages the way `BubbleCell` draws them, with the same
/// strings and the same text system, off the main actor. A
/// timeline's worth runs in parallel: 10,000 messages take a fraction of a
/// second on Apple silicon, which the main actor never waits for.
nonisolated enum TimelineLayoutEngine {
    static func layouts(for sources: [BubbleSource], widthLimit: CGFloat) -> [BubbleLayout] {
        guard sources.count > 32 else {
            return sources.map { layout(for: $0, widthLimit: widthLimit) }
        }
        let chunkSize = 64
        let chunkCount = (sources.count + chunkSize - 1) / chunkSize
        let results = UnsafeMutableBufferPointer<BubbleLayout?>.allocate(capacity: sources.count)
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

    static func layout(for source: BubbleSource, widthLimit: CGFloat) -> BubbleLayout {
        typealias G = TimelineGeometry
        typealias T = TimelineText
        let fromMe = source.fromMe
        let hasText = !source.text.isEmpty
        let picture = source.attachment?.picture
        // Emoji alone, stickers and round video messages float without a
        // bubble, in the ordinary text colours.
        let bare = (source.emojiOnly && source.quote == nil && source.attachment == nil) || picture?.isBare == true
        // Photos and videos run almost to the bubble's edge.
        let media = picture != nil && !bare
        let onAccent = fromMe && !bare
        let colors = source.colors
        let fonts = T.bodyFonts(scale: colors.textScale)
        let textColor: NSColor = onAccent ? colors.outgoingText : .labelColor
        let secondary: NSColor = onAccent ? T.faded(colors.outgoingText, 0.7) : .secondaryLabelColor
        let linkColor: NSColor = onAccent ? colors.outgoingText : colors.accent
        // Sides, top and bottom, as `MessageBubble` pads each kind.
        let side: CGFloat = bare ? 0 : media ? G.mediaPadding : G.bubblePadding.width
        let top: CGFloat = bare ? 0 : media ? G.mediaPadding : G.bubblePadding.height
        let bottom: CGFloat = bare ? 0 : G.bubblePadding.height
        // Text beside a photo keeps the usual inset.
        let inset: CGFloat = media ? G.mediaTextInset : 0
        let contentLimit = widthLimit - side * 2
        // The time tucks into the last line of plain text; after large
        // emoji or an attachment it is a line of its own on the trailing
        // edge, as `MessageBubble` places it.
        let inlineFooter = hasText && !source.emojiOnly && source.attachment == nil && source.linkPreview == nil
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
                .font: T.callout, .foregroundColor: T.faded(textColor, 0.85), .paragraphStyle: paragraph,
            ])
        }
        let placeholderColor = T.faded(textColor, 0.75)
        let placeholderText: NSAttributedString? = if case .placeholder(_, let text) = source.attachment {
            NSAttributedString(string: text, attributes: [
                .font: T.bodyItalic, .foregroundColor: placeholderColor, .paragraphStyle: T.wrapping,
            ])
        } else {
            nil
        }
        let body = hasText ? T.body(source, fonts: fonts, color: textColor, link: linkColor) : nil
        let bodyLength = body?.length ?? 0
        if inlineFooter { body?.append(T.reserve(width: footerWidth + G.footerSpacing * 2, fonts: fonts)) }

        let document: BubbleSource.Document? = if case .document(let document) = source.attachment { document } else { nil }
        let linkCard = source.linkPreview.map { linkCardTexts($0, color: textColor) }

        // A picture keeps its shape; one too wide for the timeline shrinks.
        var pictureSize = picture?.displaySize ?? .zero
        if pictureSize.width > contentLimit {
            pictureSize = CGSize(width: contentLimit, height: (pictureSize.height * contentLimit / pictureSize.width).rounded())
        }

        let quoteChrome = G.quotePadding * 3 + G.quoteBarWidth
        let placeholderChrome = G.placeholderIconWidth + G.placeholderSpacing
        let width: CGFloat
        if media {
            // The photo sets the width; everything else fits it, as on
            // the phone.
            width = pictureSize.width
        } else {
            var ideal = body.map { T.size($0).width } ?? 0
            if !inlineFooter { ideal = max(ideal, footerWidth + capsuleInset * 2) }
            if let name { ideal = max(ideal, T.size(name).width) }
            if let forwarded { ideal = max(ideal, G.forwardedIconWidth + G.footerSpacing + T.size(forwarded).width) }
            if let quoteName, let quoteSummary {
                ideal = max(ideal, quoteChrome + max(T.size(quoteName).width, T.size(quoteSummary).width))
            }
            if let placeholderText { ideal = max(ideal, placeholderChrome + T.size(placeholderText).width) }
            ideal = max(ideal, pictureSize.width)
            if document != nil { ideal = max(ideal, G.documentWidth) }
            if let card = linkCard { ideal = max(ideal, card.ideal) }
            width = min(ceil(ideal), contentLimit)
        }

        // Top to bottom, in the bubble's coordinates. Text parts sit
        // `inset` in from the sides; the quote and the picture do not.
        let left = side
        let textLeft = side + inset
        let textWidth = width - inset * 2
        var y = top
        func advance(_ height: CGFloat) -> CGFloat {
            defer { y += height + G.partSpacing }
            return y
        }

        let namePiece = name.map { string in
            let height = T.size(string).height
            return TextPiece(string: string, rect: CGRect(x: textLeft, y: advance(height), width: textWidth, height: height))
        }

        var forwardedIcon: CGRect?
        let forwardedPiece = forwarded.map { string in
            let height = T.size(string).height
            let top = advance(height)
            forwardedIcon = CGRect(x: textLeft, y: top, width: G.forwardedIconWidth, height: height)
            let x = textLeft + G.forwardedIconWidth + G.footerSpacing
            return TextPiece(string: string, rect: CGRect(x: x, y: top, width: textWidth - (x - textLeft), height: height))
        }

        var quote: BubbleLayout.QuoteLayout?
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

        var placeholder: BubbleLayout.Placeholder?
        if case .placeholder(let symbol, _) = source.attachment, let placeholderText {
            let textWidth = max(1, width - placeholderChrome)
            let textHeight = T.size(placeholderText, width: textWidth).height
            let top = advance(textHeight)
            let lineHeight = T.height(ofLines: 1, T.bodyItalic)
            placeholder = .init(
                symbol: symbol,
                icon: CGRect(x: left, y: top, width: G.placeholderIconWidth, height: lineHeight),
                text: TextPiece(string: placeholderText, rect: CGRect(
                    x: left + placeholderChrome, y: top, width: textWidth, height: textHeight
                )),
                color: placeholderColor
            )
        }

        let pictureLayout = picture.map { picture in
            let frame = CGRect(origin: CGPoint(x: left, y: advance(pictureSize.height)), size: pictureSize)
            return pictureOverlays(picture, frame: frame)
        }

        let documentLayout = document.map { document in
            var card = documentCard(document, width: min(G.documentWidth, width), color: textColor)
            card.frame.origin = CGPoint(x: left, y: advance(card.frame.height))
            return card
        }

        let bodyPiece = body.map { body in
            let height = T.size(body, width: textWidth).height
            let drawn = NSMutableAttributedString(attributedString: body)
            drawn.removeAttribute(.link, range: NSRange(location: 0, length: drawn.length))
            return TextPiece(string: drawn, rect: CGRect(x: textLeft, y: advance(height), width: textWidth, height: height))
        }
        let linkLayout = linkCard.map { texts in
            // `MessageContentView` spaces the card from the text by more.
            if bodyPiece != nil { y += Metrics.s - G.partSpacing }
            var card = linkPreviewCard(texts, width: width)
            card.frame.origin = CGPoint(x: left, y: advance(card.frame.height))
            return card
        }

        let footerRect: CGRect
        var capsule: CGRect?
        if inlineFooter, let bodyRect = bodyPiece?.rect {
            footerRect = CGRect(
                x: textLeft + textWidth - footerWidth,
                y: bodyRect.maxY + G.footerDrop - footerHeight,
                width: footerWidth,
                height: footerHeight
            )
        } else {
            let top = advance(footerHeight)
            footerRect = CGRect(
                x: textLeft + textWidth - capsuleInset - footerWidth, y: top, width: footerWidth, height: footerHeight
            )
            if bare { capsule = footerRect.insetBy(dx: -capsuleInset, dy: 0) }
        }
        let bubbleHeight = y - G.partSpacing + bottom
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

        return BubbleLayout(.init(
            widthLimit: widthLimit,
            fromMe: fromMe,
            startsRun: source.startsRun,
            bare: bare,
            bubbleSize: CGSize(width: width + side * 2, height: ceil(bubbleHeight)),
            name: namePiece,
            forwarded: forwardedPiece,
            forwardedIcon: forwardedIcon,
            quote: quote,
            placeholder: placeholder,
            picture: pictureLayout,
            document: documentLayout,
            linkPreview: linkLayout,
            body: bodyPiece,
            bodyLength: bodyLength,
            linkedBody: body,
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
            accessibilityLabel: accessibilityLabel(
                source, title: pictureLayout?.accessibilityTitle ?? documentLayout?.accessibilityTitle, time: time.string
            )
        ))
    }

    /// `DocumentContent`'s card at `width`: the first page, 150 points of
    /// it, above the row of icon, name and detail, and the download arrow
    /// while the file is not here. Its origin is set by the caller.
    private static func documentCard(_ document: BubbleSource.Document, width: CGFloat, color: NSColor) -> BubbleLayout.DocumentLayout {
        typealias G = TimelineGeometry
        typealias T = TimelineText
        let s = Metrics.s
        let top: CGFloat = document.hasPreview ? G.documentPreviewHeight : 0
        let waiting = document.path == nil
        // icon · text · spacer (at least s) · arrow, s apart, s inside.
        let textX = s + G.documentIcon + s
        let textWidth = max(1, width - textX - s - s - s - (waiting ? s + G.documentIndicator : 0))
        let name = T.lines(document.fileName, T.bodyMedium, color)
        let nameHeight = T.height(name, width: textWidth, lines: 2, font: T.bodyMedium)
        let detail = T.line(document.detail, T.caption, T.faded(color, 0.75))
        let detailHeight = T.size(detail).height
        let texts = nameHeight + 2 + detailHeight
        let inner = max(G.documentIcon, texts)
        let row = top + s
        return .init(
            document: document,
            frame: CGRect(x: 0, y: 0, width: width, height: top + inner + s * 2),
            preview: document.hasPreview ? CGRect(x: 0, y: 0, width: width, height: top) : nil,
            icon: CGRect(x: s, y: row + ((inner - G.documentIcon) / 2).rounded(), width: G.documentIcon, height: G.documentIcon),
            name: TextPiece(string: name, rect: CGRect(x: textX, y: row + ((inner - texts) / 2).rounded(), width: textWidth, height: nameHeight)),
            detail: TextPiece(string: detail, rect: CGRect(
                x: textX, y: row + ((inner - texts) / 2).rounded() + nameHeight + 2, width: textWidth, height: detailHeight
            )),
            indicator: waiting ? CGRect(
                x: width - s - G.documentIndicator, y: row + ((inner - G.documentIndicator) / 2).rounded(),
                width: G.documentIndicator, height: G.documentIndicator
            ) : nil,
            accessibilityTitle: [document.fileName, document.detail].filter { !$0.isEmpty }.joined(separator: ", ")
        )
    }

    /// `LinkPreviewCard`'s texts and how wide the card would like to be.
    private struct LinkCardTexts {
        var preview: BubbleSource.LinkPreview
        var title: NSAttributedString?
        var description: NSAttributedString?
        var host: NSAttributedString
        var ideal: CGFloat
    }

    private static func linkCardTexts(_ preview: BubbleSource.LinkPreview, color: NSColor) -> LinkCardTexts {
        typealias T = TimelineText
        let title = preview.title.map { T.lines($0, T.calloutSemibold, color) }
        let description = preview.description.map { T.lines($0, T.caption, T.faded(color, 0.8)) }
        let host = T.line(URL(string: preview.url)?.host() ?? preview.url, T.caption2, T.faded(color, 0.7))
        let widest = [title, description, host].compactMap { $0.map { T.size($0).width } }.max() ?? 0
        let image = preview.thumbnail == nil ? 0 : TimelineGeometry.linkImage + Metrics.s
        return .init(preview: preview, title: title, description: description, host: host, ideal: Metrics.s * 2 + image + widest)
    }

    /// The card at `width`: the picture top left, the texts beside it. Its
    /// origin is set by the caller.
    private static func linkPreviewCard(_ texts: LinkCardTexts, width: CGFloat) -> BubbleLayout.LinkPreviewLayout {
        typealias T = TimelineText
        let s = Metrics.s
        let image = texts.preview.thumbnail == nil ? nil : CGRect(x: s, y: s, width: TimelineGeometry.linkImage, height: TimelineGeometry.linkImage)
        let textX = image.map { $0.maxX + s } ?? s
        let textWidth = max(1, width - textX - s)
        var y = s
        func piece(_ string: NSAttributedString?, lines: Int, font: NSFont) -> TextPiece? {
            guard let string else { return nil }
            if y > s { y += 2 }
            let height = T.height(string, width: textWidth, lines: lines, font: font)
            defer { y += height }
            return TextPiece(string: string, rect: CGRect(x: textX, y: y, width: textWidth, height: height))
        }
        let title = piece(texts.title, lines: 2, font: T.calloutSemibold)
        let description = piece(texts.description, lines: 2, font: T.caption)
        let host = piece(texts.host, lines: 1, font: T.caption2)!
        let height = max(image.map { $0.maxY } ?? 0, y) + s
        return .init(
            preview: texts.preview, frame: CGRect(x: 0, y: 0, width: width, height: height),
            image: image, title: title, description: description, host: host
        )
    }

    /// The play button, the length and "GIF", placed as `VisualMedia`'s
    /// overlay places them.
    private static func pictureOverlays(_ picture: BubbleSource.Picture, frame: CGRect) -> BubbleLayout.PictureLayout {
        typealias T = TimelineText
        let bounds = CGRect(origin: .zero, size: frame.size)
        let video = picture.kind == .video || picture.kind == .roundVideo
        func label(_ text: String, font: NSFont) -> (NSAttributedString, CGSize) {
            let string = T.line(text, font, .white)
            let size = T.size(string)
            return (string, CGSize(width: size.width + 12, height: size.height + 4))
        }
        var duration: BubbleLayout.PictureLayout.Label?
        var length: String?
        if let seconds = picture.seconds, seconds > 0, picture.kind != .gif {
            length = Duration.seconds(Int(seconds)).formatted(.time(pattern: .minuteSecond))
            let (string, size) = label(length ?? "", font: T.caption2Digits)
            let x = picture.kind == .roundVideo ? (bounds.width - size.width) / 2 : Metrics.s
            let capsule = CGRect(x: x.rounded(), y: bounds.maxY - Metrics.s - size.height, width: size.width, height: size.height)
            duration = .init(capsule: capsule, text: TextPiece(string: string, rect: capsule.insetBy(dx: 6, dy: 2)))
        }
        var gif: BubbleLayout.PictureLayout.Label?
        if picture.kind == .gif {
            let (string, size) = label("GIF", font: T.captionBold)
            let capsule = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
            gif = .init(capsule: capsule, text: TextPiece(string: string, rect: capsule.insetBy(dx: 6, dy: 2)))
        }
        let glyphSize: CGFloat = 44
        let glyph = video && picture.path != nil
            ? CGRect(x: ((bounds.width - glyphSize) / 2).rounded(), y: ((bounds.height - glyphSize) / 2).rounded(), width: glyphSize, height: glyphSize)
            : nil
        let title: String = switch picture.kind {
        case .sticker, .animatedSticker: String(localized: "Sticker")
        case .gif: String(localized: "GIF")
        case .photo: String(localized: "Photo")
        case .video: length.map { String(localized: "Video, \($0)") } ?? String(localized: "Video")
        case .roundVideo: length.map { String(localized: "Video message, \($0)") } ?? String(localized: "Video message")
        }
        return .init(
            picture: picture,
            frame: frame,
            cornerRadius: picture.isSticker ? 0 : Metrics.bubbleRadius - Metrics.xs,
            circle: picture.kind == .roundVideo,
            glyph: glyph,
            duration: duration,
            gif: gif,
            points: max(frame.width, frame.height),
            accessibilityTitle: title
        )
    }

    private static let twoCalloutLines = TimelineText.height(ofLines: 2, TimelineText.callout)

    /// Reactions grouped by emoji, most chosen first, as `ReactionPills`.
    private static func reactionPills(_ reactions: [ReactionInfo]) -> ([BubbleLayout.Pill], CGSize) {
        guard !reactions.isEmpty else { return ([], .zero) }
        let groups = Dictionary(grouping: reactions, by: \.emoji)
            .map { (emoji: $0.key, count: $0.value.count, mine: $0.value.contains(where: \.fromMe)) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.emoji < $1.emoji }
        let padding = CGSize(width: 6, height: 2)
        var pills: [BubbleLayout.Pill] = []
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

    private static func accessibilityLabel(_ source: BubbleSource, title: String?, time: String) -> String {
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
        if case .placeholder(_, let text) = source.attachment { parts.append(text) }
        if let title { parts.append(title) }
        if !source.text.isEmpty { parts.append(source.text) }
        if source.edited { parts.append(String(localized: "Edited")) }
        parts.append(time)
        return parts.joined(separator: ", ")
    }
}
