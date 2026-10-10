/// The bubble a message is drawn in: its shape, its text layers, and the
/// pointer work that belongs to the bubble rather than to the row.

import AppKit
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// The bubble: its shape as a layer background, text in two layers (the
/// body alone, so a text view can stand in for it).
final class BubbleView: NSView {
    weak var cell: BubbleCell?
    private(set) var bodyText: BodyTextView?
    private(set) var pictureView: PictureView?
    private(set) var documentView: DocumentView?
    private(set) var voiceView: VoiceView?
    private(set) var linkView: LinkPreviewView?
    private let chrome = BubbleChromeLayer()
    private let body = TextLayer()
    /// The words a search found, under the body's text.
    private let searchMarks = CAShapeLayer()
    private var marked: SearchMarking?
    /// The quoted message's picture, on the quote's right.
    private let quoteImage = CALayer()
    private var quoteLoads = 0
    private var bubbleLayout: BubbleLayout?
    private var bodyHover: Task<Void, Never>?
    private var overBody = false
    private var overPicture = false
    private var pictureRest: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.cornerRadius = Metrics.bubbleRadius
        layer?.cornerCurve = .continuous
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 0.5
        layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(chrome)
        searchMarks.isHidden = true
        searchMarks.actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "hidden": NSNull(), "fillColor": NSNull()]
        layer?.addSublayer(searchMarks)
        layer?.addSublayer(body)
        quoteImage.contentsGravity = .resizeAspectFill
        quoteImage.masksToBounds = true
        quoteImage.cornerRadius = Metrics.controlRadius
        quoteImage.cornerCurve = .continuous
        // Flush with the quote's right edge, whose corners it rounds.
        quoteImage.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        quoteImage.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(quoteImage)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func configure(_ layout: BubbleLayout, messageID: String) {
        bubbleLayout = layout
        if let picture = layout.picture {
            let view = install(&pictureView, frame: picture.frame) { PictureView() }
            view.cell = cell
            view.configure(picture, messageID: messageID, color: layout.textColor)
        } else {
            remove(&pictureView)
        }
        if let document = layout.document {
            let view = install(&documentView, frame: document.frame) { DocumentView() }
            view.cell = cell
            view.configure(document, messageID: messageID, color: layout.textColor)
        } else {
            remove(&documentView)
        }
        if let voice = layout.voice {
            let view = install(&voiceView, frame: voice.frame) { VoiceView() }
            view.cell = cell
            view.configure(voice, messageID: messageID, bubbleColor: layout.bubbleColor)
        } else {
            remove(&voiceView)
        }
        if let preview = layout.linkPreview {
            let view = install(&linkView, frame: preview.frame) { LinkPreviewView() }
            view.cell = cell
            view.configure(preview, messageID: messageID)
        } else {
            remove(&linkView)
        }
        overPicture = false
        showQuotePicture(layout.quote, messageID: messageID)
        chrome.layout = layout
        body.piece = layout.body.map { TextPiece(string: $0.string, rect: CGRect(origin: .zero, size: $0.rect.size)) }
        body.isHidden = layout.body == nil
        applyAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chrome.frame = CGRect(origin: .zero, size: layout.bubbleSize)
        body.frame = layout.body?.rect ?? .zero
        CATransaction.commit()
        chrome.setNeedsDisplay()
        body.setNeedsDisplay()
        overBody = false
        bodyHover?.cancel()
        // Another layout: whatever was marked is measured again.
        marked = nil
        searchMarks.isHidden = true
    }

    /// Marks the words a search found in the body, as the archive matched
    /// them, measured by TextKit as the body's text view lays it out; the
    /// match on screen in a stronger colour.
    func setSearchMarks(_ marking: SearchMarking?) {
        guard marking != marked || (marking != nil && searchMarks.isHidden) else { return }
        marked = marking
        guard let marking, let body = bubbleLayout?.body else {
            searchMarks.isHidden = true
            return
        }
        let ranges = SearchMarks.ranges(in: body.string.string, matching: marking.query)
        guard !ranges.isEmpty else {
            searchMarks.isHidden = true
            return
        }
        let path = CGMutablePath()
        for rect in Self.rects(of: ranges, in: body.string, width: body.rect.width) {
            path.addRoundedRect(in: rect.insetBy(dx: -1.5, dy: 0), cornerWidth: 3, cornerHeight: 3)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        searchMarks.frame = body.rect
        searchMarks.path = path
        searchMarks.fillColor = Self.markColor(current: marking.current, onAccent: bubbleLayout?.fromMe == true)
        searchMarks.isHidden = false
        CATransaction.commit()
    }

    /// Yellow under dark text, as a highlighter marks paper; white under
    /// the white text of our own bubbles, whose accent yellow would muddy.
    /// The match on screen is marked more strongly than the others.
    static func markColor(current: Bool, onAccent: Bool) -> CGColor {
        if onAccent {
            return NSColor.white.withAlphaComponent(current ? 0.45 : 0.22).cgColor
        }
        return NSColor.systemYellow.withAlphaComponent(current ? 0.7 : 0.3).cgColor
    }

    /// Where `ranges` of `string` fall when it is laid out `width` wide,
    /// one rectangle per line each covers.
    static func rects(of ranges: [NSRange], in string: NSAttributedString, width: CGFloat) -> [CGRect] {
        let storage = NSTextStorage(attributedString: string)
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        var rects: [CGRect] = []
        for range in ranges where NSMaxRange(range) <= string.length {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(
                forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in
                rects.append(rect)
            }
        }
        return rects
    }

    func refreshColors() {
        applyAppearance()
        chrome.setNeedsDisplay()
        body.setNeedsDisplay()
    }

    private func showQuotePicture(_ quote: BubbleLayout.QuoteLayout?, messageID: String) {
        quoteLoads += 1
        let load = quoteLoads
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        quoteImage.frame = quote?.thumbnail ?? .zero
        quoteImage.isHidden = quote?.thumbnail == nil
        CATransaction.commit()
        guard let rect = quote?.thumbnail, let data = quote?.thumbnailData else {
            quoteImage.contents = nil
            return
        }
        let key = "quote-\(messageID)"
        let points = max(rect.width, rect.height)
        if let cached = Thumbnails.cached(key: key, points: points) {
            quoteImage.contents = cached.cgImage(forProposedRect: nil, context: nil, hints: nil)
            return
        }
        quoteImage.contents = nil
        Task { [weak self] in
            let image = await Thumbnails.load(data, key: key, points: points)
            guard let self, self.quoteLoads == load else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.quoteImage.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            CATransaction.commit()
        }
    }

    /// The attachment's view, made the first time a message needs it.
    private func install<View: NSView>(_ view: inout View?, frame: CGRect, make: () -> View) -> View {
        let made = view ?? make()
        if made.superview == nil { addSubview(made) }
        made.frame = frame
        view = made
        return made
    }

    private func remove<View: NSView>(_ view: inout View?) {
        view?.removeFromSuperview()
        view = nil
    }

    private func applyAppearance() {
        guard let layout = bubbleLayout else { return }
        chrome.appearance = effectiveAppearance
        body.appearance = effectiveAppearance
        // Without a bubble there is no shape to round, and the rounding
        // would clip the sender's name at the corner.
        layer?.cornerRadius = layout.bare ? 0 : Metrics.bubbleRadius
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = layout.bubbleColor?.cgColor
        }
        let lifted = layout.lifted && layout.bubbleColor != nil
        layer?.shadowOpacity = lifted ? 0.1 : 0
        if lifted {
            // A known shape, so the shadow needs no offscreen pass.
            layer?.shadowPath = CGPath(
                roundedRect: CGRect(origin: .zero, size: layout.bubbleSize),
                cornerWidth: Metrics.bubbleRadius, cornerHeight: Metrics.bubbleRadius, transform: nil
            )
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        chrome.contentsScale = scale
        body.contentsScale = scale
        chrome.setNeedsDisplay()
        body.setNeedsDisplay()
    }

    func showBodyText(_ view: BodyTextView) {
        bodyText = view
        addSubview(view)
        body.isHidden = true
    }

    func hideBodyText() {
        guard let view = bodyText else { return }
        if view.window?.firstResponder === view { view.window?.makeFirstResponder(view.enclosingScrollView?.documentView) }
        view.removeFromSuperview()
        bodyText = nil
        body.isHidden = false
    }

    // MARK: Pointer

    /// The text view is made once the pointer rests on the text: made for
    /// every bubble the pointer crossed while scrolling, text views were
    /// most of the frame in Telefast's traces. The quote and the sender's
    /// name show the pointing hand.
    func pointerMoved(to point: NSPoint) {
        guard let layout = bubbleLayout else { return }
        let clickable = layout.quote?.rect.contains(point) == true || layout.name?.rect.contains(point) == true
            || layout.linkPreview?.frame.contains(point) == true
        if bodyText == nil { (clickable ? NSCursor.pointingHand : NSCursor.arrow).set() }
        let picture = layout.picture?.frame.contains(point) == true
        if picture != overPicture {
            overPicture = picture
            pictureRest?.cancel()
            if picture {
                // A GIF moves once the pointer rests on it, not as it passes.
                pictureRest = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(BubbleCell.restDelay))
                    guard let self, !Task.isCancelled else { return }
                    self.pointerRested()
                }
            } else {
                pictureView?.setMoving(false)
            }
        }
        let body = layout.body?.rect.contains(point) == true
        guard body != overBody else { return }
        overBody = body
        bodyHover?.cancel()
        if body {
            bodyHover = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(BubbleCell.restDelay))
                guard let self, !Task.isCancelled, let cell = self.cell else { return }
                cell.delegate?.bodyHovered(in: cell)
            }
        } else if let view = bodyText, view.selectedRange().length == 0 {
            hideBodyText()
        }
    }

    /// The pointer rested on the row: a GIF or animated sticker under it
    /// moves.
    func pointerRested() {
        guard overPicture, let window, window.isKeyWindow else { return }
        pictureView?.setMoving(true)
    }

    func pointerLeft() {
        overBody = false
        overPicture = false
        pictureRest?.cancel()
        pictureView?.setMoving(false)
        bodyHover?.cancel()
        NSCursor.arrow.set()
        if let view = bodyText, view.selectedRange().length == 0 { hideBodyText() }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // ⌘-click selects messages; the cell handles it.
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let quote = bubbleLayout?.quote, quote.rect.contains(point), let cell, let id = cell.messageID {
            cell.delegate?.showQuote(ofMessage: id)
            return
        }
        if let name = bubbleLayout?.name, name.rect.contains(point), let cell, let id = cell.messageID {
            cell.delegate?.showSender(ofMessage: id, relativeTo: name.rect, of: self, preferredEdge: .minY)
            return
        }
        if let bodyRect = bubbleLayout?.body?.rect, bodyRect.contains(point), let cell, let view = cell.installBodyText() {
            view.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let cell, let id = cell.messageID else { return nil }
        return cell.delegate?.menu(forMessage: id, selection: nil)
    }

}

/// Everything in a bubble except the body: sender, forwarded, the quote and
/// the footer.
nonisolated private final class BubbleChromeLayer: CALayer {
    // Set on the main thread; read in draw(in:), which Core Animation also
    // calls on the main thread, during the commit.
    nonisolated(unsafe) var layout: BubbleLayout?
    nonisolated(unsafe) var appearance: NSAppearance?

    override init() {
        super.init()
        contentsFormat = .RGBA8Uint
        contentsScale = 2
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func action(forKey event: String) -> (any CAAction)? { nil }

    override func draw(in context: CGContext) {
        guard let layout else { return }
        nonisolated(unsafe) let context = context
        nonisolated(unsafe) let appearance = appearance
        MainActor.assumeIsolated {
            withAppKitContext(context, appearance: appearance) { Self.draw(layout) }
        }
    }


    @MainActor
    private static let capsuleFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.17, alpha: 0.9)
            : NSColor(white: 0.93, alpha: 0.9)
    }

    @MainActor
    private static func draw(_ layout: BubbleLayout) {
        layout.name?.draw(options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        layout.phone?.draw(options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let placeholder = layout.placeholder {
            Symbols.draw(placeholder.symbol, in: placeholder.icon, pointSize: TimelineText.body.pointSize, weight: .regular, color: placeholder.color)
            placeholder.text.draw()
        }
        if let forwarded = layout.forwarded, let icon = layout.forwardedIcon {
            Symbols.draw("arrowshape.turn.up.right", in: icon, pointSize: TimelineText.caption.pointSize, weight: .regular, color: layout.footer.secondary)
            forwarded.draw(options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if let quote = layout.quote {
            let shape = NSBezierPath(roundedRect: quote.rect, xRadius: Metrics.controlRadius, yRadius: Metrics.controlRadius)
            AppKitPalette.inset.setFill()
            shape.fill()
            // The bar is the quote's left edge, rounded with its corners.
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            quote.barColor.setFill()
            quote.bar.fill()
            NSGraphicsContext.restoreGraphicsState()
            quote.name.draw(options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            quote.phone?.draw(options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if let symbol = quote.symbol, let rect = quote.symbolRect {
                Symbols.draw(symbol, in: rect, pointSize: quote.symbolSize, weight: .regular, color: quote.symbolColor)
            }
            quote.summary.draw(options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        }
        let footer = layout.footer
        if let capsule = footer.capsule {
            // The material SwiftUI puts behind it, as a nearly opaque fill
            // that reads over a wallpaper or a photo.
            capsuleFill.setFill()
            NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()
        }
        footer.edited?.draw()
        footer.time.draw()
        if let ticks = footer.ticks {
            Symbols.drawTicks(DeliveryTicks.State(footer.state), in: ticks, secondary: footer.secondary, read: footer.tint)
        }
    }
}

/// One piece of text in its own 8-bit layer.
nonisolated final class TextLayer: CALayer {
    nonisolated(unsafe) var piece: TextPiece?
    nonisolated(unsafe) var appearance: NSAppearance?

    override init() {
        super.init()
        contentsFormat = .RGBA8Uint
        contentsScale = 2
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func action(forKey event: String) -> (any CAAction)? { nil }

    override func draw(in context: CGContext) {
        guard let piece else { return }
        nonisolated(unsafe) let context = context
        nonisolated(unsafe) let appearance = appearance
        MainActor.assumeIsolated {
            withAppKitContext(context, appearance: appearance) { piece.draw() }
        }
    }
}

/// An SF Symbol centred in its own 8-bit layer: one colour, or a palette
/// of several for symbols drawn in layers (a play button's circle).
nonisolated final class SymbolLayer: CALayer {
    nonisolated(unsafe) private var symbol: String?
    nonisolated(unsafe) private var pointSize: CGFloat = 13
    nonisolated(unsafe) private var weight: NSFont.Weight = .regular
    nonisolated(unsafe) private var palette: [NSColor] = []
    nonisolated(unsafe) var appearance: NSAppearance?

    override init() {
        super.init()
        contentsFormat = .RGBA8Uint
        contentsScale = 2
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func action(forKey event: String) -> (any CAAction)? { nil }

    /// Whether this changed what the layer draws.
    @MainActor
    @discardableResult
    func configure(symbol: String, pointSize: CGFloat, weight: NSFont.Weight, palette: [NSColor]) -> Bool {
        guard symbol != self.symbol || pointSize != self.pointSize || weight != self.weight || palette != self.palette else { return false }
        self.symbol = symbol
        self.pointSize = pointSize
        self.weight = weight
        self.palette = palette
        setNeedsDisplay()
        return true
    }

    override func draw(in context: CGContext) {
        guard let symbol else { return }
        nonisolated(unsafe) let context = context
        nonisolated(unsafe) let appearance = appearance
        let bounds = bounds
        let (pointSize, weight, palette) = (pointSize, weight, palette)
        MainActor.assumeIsolated {
            withAppKitContext(context, appearance: appearance) {
                Symbols.drawCentered(symbol, in: bounds, pointSize: pointSize, weight: weight, palette: palette)
            }
        }
    }
}
