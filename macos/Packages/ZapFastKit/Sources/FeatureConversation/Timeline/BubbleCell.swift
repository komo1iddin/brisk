import AppKit
import ZapFastBridge
import ZapFastDesign
import ZapFastSharedUI

/// What a timeline cell asks of the table's controller.
@MainActor
protocol TimelineCellDelegate: AnyObject {
    func showQuote(ofMessage id: String)
    /// The sender's name was clicked: their page in the chat's info.
    func showSender(ofMessage id: String)
    /// The message's context menu, with a Copy for `selection` when some of
    /// its text is selected.
    func menu(forMessage id: String, selection: String?) -> NSMenu?
    func open(_ url: URL)
    /// The pointer is over a message's text: it becomes selectable.
    func bodyHovered(in cell: BubbleCell)
    func bodyTextBecameActive(_ view: BodyTextView)
    /// ⌘-click: start selecting messages with this one.
    func startSelecting(fromMessage id: String)
    /// Reply and React, shown beside the bubble while the pointer is on the row.
    func hoverActions(forMessage id: String) -> NSView?
    func isPickingReaction(forMessage id: String) -> Bool
    func reactionPicker(forMessage id: String) -> NSViewController?
    func reactionPickerClosed(forMessage id: String)
    func accessibilityActions(forMessage id: String) -> [NSAccessibilityCustomAction]
}

/// A plain text message, drawn by Core Animation instead of SwiftUI.
///
/// Telefast's timeline measurements, repeated here: the bubble is a layer
/// background with rounded corners, composited by the GPU; only text is
/// rasterized, into 8-bit buffers (AppKit picks 16-bit ones on XDR displays,
/// which doubled the cost of every frame). The layout arrives measured, so
/// configuring a reused cell does no text layout at all.
///
/// Selecting text needs a text view, which costs far more than a layer, so
/// one is laid over the text only while the pointer is on it (or while it
/// keeps a selection), set up with the same string and width so nothing
/// moves when it appears.
final class BubbleCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("TimelineBubble")

    weak var delegate: TimelineCellDelegate?
    private(set) var messageID: String?
    private(set) var bubbleLayout: BubbleLayout?
    private let bubble = BubbleView()
    private let pills = ReactionPillsView()
    private var highlighted = false
    /// Reply and React beside the bubble, made once the pointer rests on
    /// the row: a row swept past while scrolling makes none.
    private var hoverActions: NSView?
    private var hoverTask: Task<Void, Never>?
    private var hovering = false
    private var popover: NSPopover?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        addSubview(bubble)
        addSubview(pills)
        bubble.cell = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func configure(id: String, layout: BubbleLayout, highlighted: Bool) {
        if id != messageID || layout !== bubbleLayout {
            if id != messageID {
                // A reused cell shows another message.
                hideHoverActions(animated: false)
                popover?.close()
            }
            messageID = id
            bubbleLayout = layout
            removeBodyText()
            bubble.configure(layout)
            pills.configure(layout)
            placeSubviews()
            setAccessibilityLabel(layout.accessibilityLabel)
        }
        setHighlighted(highlighted, animated: false)
    }

    /// The system accent colour changed.
    func refreshColors() {
        bubble.refreshColors()
        pills.needsRedraw()
    }

    func setHighlighted(_ on: Bool, animated: Bool) {
        guard on != highlighted else { return }
        highlighted = on
        let accent = bubbleLayout?.accent ?? .controlAccentColor
        var color = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if on { color = accent.withAlphaComponent(0.18).cgColor }
        }
        CATransaction.begin()
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            CATransaction.setAnimationDuration(0.6)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        layer?.backgroundColor = color
        CATransaction.commit()
    }

    /// Frames are set here, not in `layout()`: marking a cell as needing
    /// layout sends the window's layout pass through the SwiftUI hosting
    /// view at its root on every reuse, which cost more than the cells.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { placeSubviews() }
    }

    private func placeSubviews() {
        guard let layout = bubbleLayout else { return }
        bubble.frame = layout.bubbleFrame(rowWidth: bounds.width)
        pills.isHidden = layout.pills.isEmpty
        if !layout.pills.isEmpty { pills.frame = layout.pillsFrame(rowWidth: bounds.width).insetBy(dx: -2, dy: -2) }
        placeHoverActions()
    }

    // MARK: Pointer

    /// The pointer is over this row, at `point` (the table tracks it: cells
    /// have no tracking areas or cursor rects of their own, which AppKit
    /// recomputed for every cell on every frame of a scroll).
    func pointerMoved(to point: NSPoint) {
        if !hovering {
            hovering = true
            hoverTask?.cancel()
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.restDelay))
                guard let self, !Task.isCancelled, self.hovering else { return }
                self.showHoverActions()
            }
        }
        let inBubble = bubble.convert(point, from: self)
        bubble.pointerMoved(to: inBubble)
    }

    /// The pointer left the row, or the row went off screen under it.
    func pointerLeft() {
        guard hovering else { return }
        hovering = false
        hoverTask?.cancel()
        bubble.pointerLeft()
        guard let id = messageID, delegate?.isPickingReaction(forMessage: id) != true else { return }
        hideHoverActions(animated: true)
    }

    /// How long the pointer rests before a row makes its hover views.
    static let restDelay = 150

    private func showHoverActions() {
        guard hoverActions == nil, let id = messageID, let view = delegate?.hoverActions(forMessage: id) else { return }
        hoverActions = view
        view.alphaValue = 0
        addSubview(view)
        placeHoverActions()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            view.animator().alphaValue = 1
        }
    }

    private func hideHoverActions(animated: Bool) {
        guard let view = hoverActions else { return }
        hoverActions = nil
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            view.removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            view.animator().alphaValue = 0
        } completionHandler: {
            // AppKit calls this on the main thread.
            MainActor.assumeIsolated { view.removeFromSuperview() }
        }
    }

    /// Beside the bubble, clear of it, on the side away from the window's
    /// edge, centred on it, as `MessageRow` places them.
    private func placeHoverActions() {
        guard let view = hoverActions, let layout = bubbleLayout else { return }
        let bubble = layout.bubbleFrame(rowWidth: bounds.width)
        let size = view.frame.size
        let gap = HoverActions.gap
        let x = layout.fromMe ? bubble.minX - gap - size.width : bubble.maxX + gap
        view.setFrameOrigin(NSPoint(x: x.rounded(), y: (bubble.midY - size.height / 2).rounded()))
    }

    /// The reaction picker, from the hover control or the message's menu.
    func showReactionPicker() {
        guard popover == nil, let id = messageID, let controller = delegate?.reactionPicker(forMessage: id) else { return }
        showHoverActions()
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: bubble.bounds, of: bubble, preferredEdge: .minY)
    }

    func closeReactionPicker() {
        popover?.close()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let id = messageID {
            delegate?.startSelecting(fromMessage: id)
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Selectable text

    var bodyText: BodyTextView? { bubble.bodyText }

    func installBodyText() -> BodyTextView? {
        guard let layout = bubbleLayout, bubble.bodyText == nil else { return bubble.bodyText }
        let view = BodyTextView(layout: layout)
        view.cell = self
        bubble.showBodyText(view)
        return view
    }

    func removeBodyText() {
        bubble.hideBodyText()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let id = messageID else { return nil }
        return delegate?.accessibilityActions(forMessage: id)
    }
}

extension BubbleCell: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        popover = nil
        if let id = messageID { delegate?.reactionPickerClosed(forMessage: id) }
        if !hovering { hideHoverActions(animated: true) }
    }
}

// MARK: - Bubble

/// The bubble: its shape as a layer background, text in two layers (the
/// body alone, so a text view can stand in for it).
private final class BubbleView: NSView {
    weak var cell: BubbleCell?
    private(set) var bodyText: BodyTextView?
    private let chrome = BubbleChromeLayer()
    private let body = TextLayer()
    private var bubbleLayout: BubbleLayout?
    private var bodyHover: Task<Void, Never>?
    private var overBody = false

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
        layer?.addSublayer(body)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func configure(_ layout: BubbleLayout) {
        bubbleLayout = layout
        chrome.layout = layout
        body.piece = TextPiece(string: layout.body.string, rect: CGRect(origin: .zero, size: layout.body.rect.size))
        applyAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chrome.frame = CGRect(origin: .zero, size: layout.bubbleSize)
        body.frame = layout.body.rect
        CATransaction.commit()
        chrome.setNeedsDisplay()
        body.setNeedsDisplay()
        overBody = false
        bodyHover?.cancel()
    }

    func refreshColors() {
        applyAppearance()
        chrome.setNeedsDisplay()
        body.setNeedsDisplay()
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
        if bodyText == nil { (clickable ? NSCursor.pointingHand : NSCursor.arrow).set() }
        let body = layout.body.rect.contains(point)
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

    func pointerLeft() {
        overBody = false
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
            cell.delegate?.showSender(ofMessage: id)
            return
        }
        if let layout = bubbleLayout, layout.body.rect.contains(point), let cell, let view = cell.installBodyText() {
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
    private static func draw(_ layout: BubbleLayout) {
        layout.name?.draw(options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let forwarded = layout.forwarded, let icon = layout.forwardedIcon {
            Symbols.draw("arrowshape.turn.up.right", in: icon, pointSize: TimelineText.caption.pointSize, weight: .regular, color: layout.footer.secondary)
            forwarded.draw(options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if let quote = layout.quote {
            AppKitPalette.quoteBar.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: quote.rect, xRadius: Metrics.controlRadius, yRadius: Metrics.controlRadius).fill()
            quote.barColor.setFill()
            NSBezierPath(roundedRect: quote.bar, xRadius: 2, yRadius: 2).fill()
            quote.name.draw(options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            quote.summary.draw(options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        }
        let footer = layout.footer
        if let capsule = footer.capsule {
            // The material SwiftUI put behind it, as a translucent fill.
            NSColor.windowBackgroundColor.withAlphaComponent(0.85).setFill()
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

// MARK: - Reactions

/// The reaction pills under a bubble.
private final class ReactionPillsView: NSView {
    private let drawing = PillsLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.addSublayer(drawing)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func configure(_ layout: BubbleLayout) {
        drawing.layout = layout
        needsRedraw()
    }

    func needsRedraw() {
        drawing.appearance = effectiveAppearance
        drawing.setNeedsDisplay()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawing.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsRedraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawing.contentsScale = window?.backingScaleFactor ?? 2
        drawing.setNeedsDisplay()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

nonisolated private final class PillsLayer: CALayer {
    nonisolated(unsafe) var layout: BubbleLayout?
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

    override func draw(in context: CGContext) {
        guard let layout, !layout.pills.isEmpty else { return }
        nonisolated(unsafe) let context = context
        nonisolated(unsafe) let appearance = appearance
        MainActor.assumeIsolated {
            withAppKitContext(context, appearance: appearance) {
                // The view is two points larger on each side, for the shadow.
                let transform = NSAffineTransform()
                transform.translateX(by: 2, yBy: 2)
                transform.concat()
                for pill in layout.pills {
                    let path = NSBezierPath(roundedRect: pill.rect.insetBy(dx: 0.5, dy: 0.5), xRadius: pill.rect.height / 2, yRadius: pill.rect.height / 2)
                    NSGraphicsContext.saveGraphicsState()
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.black.withAlphaComponent(0.08)
                    shadow.shadowBlurRadius = 1
                    shadow.shadowOffset = NSSize(width: 0, height: -1)
                    shadow.set()
                    NSColor.textBackgroundColor.setFill()
                    path.fill()
                    NSGraphicsContext.restoreGraphicsState()
                    (pill.mine ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
                    path.lineWidth = 1
                    path.stroke()
                    pill.emoji.draw()
                    pill.count?.draw()
                }
            }
        }
    }
}

// MARK: - Selectable body

/// The body as a real text view, for selecting, copying and clicking links.
/// TextKit 1 with no padding lays the string out exactly as the string
/// drawing that measured it. The footer's room at the end is never selected
/// or copied.
final class BodyTextView: NSTextView, NSTextViewDelegate {
    weak var cell: BubbleCell?
    private let visibleLength: Int

    init(layout: BubbleLayout) {
        visibleLength = layout.bodyLength
        let storage = NSTextStorage(attributedString: layout.body.string)
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: layout.body.rect.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        super.init(frame: layout.body.rect, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        isAutomaticLinkDetectionEnabled = false
        linkTextAttributes = [.foregroundColor: layout.linkColor, .cursor: NSCursor.pointingHand]
        if layout.fromMe {
            // The usual selection colour is the accent, which the bubble is.
            selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.35)]
        }
        delegate = self
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        visibleLength = 0
        super.init(frame: frameRect, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var selectedText: String? {
        let range = selectedRange()
        guard range.length > 0 else { return nil }
        return (string as NSString).substring(with: range)
    }

    override func selectionRange(forProposedRange proposedCharRange: NSRange, granularity: NSSelectionGranularity) -> NSRange {
        let range = super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
        let end = min(NSMaxRange(range), visibleLength)
        let start = min(range.location, end)
        return NSRange(location: start, length: end - start)
    }

    override func mouseDown(with event: NSEvent) {
        // ⌘-click selects messages, on the text as anywhere on the row.
        if event.modifierFlags.contains(.command), let cell {
            cell.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { cell?.delegate?.bodyTextBecameActive(self) }
        return accepted
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let cell, let id = cell.messageID else { return nil }
        return cell.delegate?.menu(forMessage: id, selection: selectedText)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url else { return false }
        cell?.delegate?.open(url)
        return true
    }
}

// MARK: - Drawing helpers

/// Runs AppKit drawing into a layer's context, top-left based, with the
/// view's appearance so dynamic colours resolve for light or dark.
@MainActor
func withAppKitContext(_ context: CGContext, appearance: NSAppearance?, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance(draw)
    NSGraphicsContext.restoreGraphicsState()
}

/// SF Symbols drawn as tinted images, cached per name, size and colour.
@MainActor
enum Symbols {
    private static var cache: [String: NSImage] = [:]

    static func draw(_ name: String, in rect: CGRect, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor, offset: CGFloat = 0) {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(resolved.description)"
        let image: NSImage
        if let cached = cache[key] {
            image = cached
        } else {
            let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
                .applying(.init(paletteColors: [resolved]))
            guard let made = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return }
            cache[key] = made
            image = made
        }
        let size = image.size
        let origin = CGPoint(x: rect.minX + offset, y: rect.midY - size.height / 2)
        image.draw(in: CGRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// `DeliveryTicks`, drawn: one tick sent, two delivered, two tinted read.
    static func drawTicks(_ state: DeliveryTicks.State, in rect: CGRect, secondary: NSColor, read: NSColor) {
        switch state {
        case .pending:
            draw("clock", in: rect, pointSize: 9, weight: .bold, color: secondary)
        case .sent:
            draw("checkmark", in: rect, pointSize: 9, weight: .bold, color: secondary)
        case .delivered, .read:
            let color = state == .read ? read : secondary
            draw("checkmark", in: rect, pointSize: 9, weight: .bold, color: color)
            draw("checkmark", in: rect, pointSize: 9, weight: .bold, color: color, offset: 4)
        case .failed:
            draw("exclamationmark.circle.fill", in: rect, pointSize: 9, weight: .bold, color: .systemRed)
        }
    }
}
