import AppKit
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

// MARK: - Day separator and unread divider

/// `DaySeparator` and `UnreadSeparator` drawn by Core Animation: a caption
/// in a capsule of the theme's chip colour, centred, in the text colour as
/// WhatsApp's are.
final class ChipCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("TimelineChip")

    private let chip = CALayer()
    private let text = TextLayer()
    private var title: NSAttributedString?
    private var colors: BubbleColors?

    /// The chip's size and the row's height for a title. The day floating
    /// over the timeline is larger than the separators it stands in for.
    static func measure(_ title: String, large: Bool = false) -> (text: NSAttributedString, chip: CGSize, rowHeight: CGFloat) {
        let string = TimelineText.line(title, large ? TimelineText.calloutSemibold : TimelineText.captionSemibold, .labelColor)
        let size = TimelineText.size(string)
        let (across, down) = padding(large: large)
        let chip = CGSize(width: size.width + across * 2, height: size.height + down * 2)
        return (string, chip, chip.height + Metrics.s * 2)
    }

    private static func padding(large: Bool) -> (across: CGFloat, down: CGFloat) {
        large ? (Metrics.l, Metrics.xs + 2) : (Metrics.m, Metrics.xs)
    }

    /// Drawn larger: the day over the top of the timeline.
    var large = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        chip.cornerCurve = .continuous
        chip.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "shadowOpacity": NSNull()]
        chip.shadowColor = NSColor.black.cgColor
        chip.shadowRadius = 0.5
        chip.shadowOffset = CGSize(width: 0, height: 0.5)
        layer?.addSublayer(chip)
        chip.addSublayer(text)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// Floating over the timeline, the pointer goes through to it.
    var passesPointer = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesPointer ? nil : super.hitTest(point)
    }

    func configure(title: String, isHeader: Bool, colors: BubbleColors) {
        let measured = Self.measure(title, large: large)
        self.title = measured.text
        self.colors = colors
        let pad = Self.padding(large: large)
        text.piece = TextPiece(string: measured.text, rect: CGRect(
            origin: CGPoint(x: pad.across, y: pad.down),
            size: TimelineText.size(measured.text)
        ))
        setAccessibilityLabel(title)
        setAccessibilityRole(isHeader ? NSAccessibility.Role(rawValue: "AXHeading") : .staticText)
        applyAppearance()
        text.setNeedsDisplay()
        placeChip()
    }

    func refreshColors() {
        applyAppearance()
        text.setNeedsDisplay()
    }

    /// Set directly rather than in `layout()`, as `BubbleCell` does.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { placeChip() }
    }

    private func placeChip() {
        guard let title else { return }
        let size = TimelineText.size(title)
        let pad = Self.padding(large: large)
        let chipSize = CGSize(width: size.width + pad.across * 2, height: size.height + pad.down * 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chip.frame = CGRect(
            x: ((bounds.width - chipSize.width) / 2).rounded(),
            y: Metrics.s,
            width: chipSize.width,
            height: chipSize.height
        )
        chip.cornerRadius = chipSize.height / 2
        // A known shape, so the shadow needs no offscreen pass.
        chip.shadowPath = CGPath(roundedRect: chip.bounds, cornerWidth: chip.cornerRadius, cornerHeight: chip.cornerRadius, transform: nil)
        text.frame = chip.bounds
        CATransaction.commit()
    }

    private func applyAppearance() {
        text.appearance = effectiveAppearance
        let lifted = colors?.hasWallpaper ?? false
        effectiveAppearance.performAsCurrentDrawingAppearance {
            chip.backgroundColor = (colors?.chip ?? AppKitPalette.dayChip).cgColor
        }
        chip.shadowOpacity = lifted ? 0.08 : 0
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        text.contentsScale = window?.backingScaleFactor ?? 2
        text.setNeedsDisplay()
    }

    override func isAccessibilityElement() -> Bool { true }
}

// MARK: - SwiftUI rows

/// A table cell showing one SwiftUI row: photos, voice, polls, cards and
/// everything else that is not plain text.
final class HostingCell: NSTableCellView {
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    /// One reuse identifier per kind of content.
    static func identifier(for row: TimelineRow) -> NSUserInterfaceItemIdentifier {
        guard case .message(let message, _, _) = row else { return NSUserInterfaceItemIdentifier("TimelineHosting") }
        let kind: String = switch message.content {
        case .text: "text"
        case .interactive: "interactive"
        case .image: "image"
        case .video: "video"
        case .sticker: "sticker"
        case .audio: "audio"
        case .document: "document"
        case .location, .liveLocation: "location"
        case .contact: "contact"
        case .poll: "poll"
        case .stickerPack: "stickerPack"
        case .revoked, .unsupported, .phoneOnly: "placeholder"
        }
        return NSUserInterfaceItemIdentifier("TimelineHosting-\(kind)")
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        host.sizingOptions = []
        // Sized by its mask, not constraints of its own: constraints in
        // scrolled cells send each reuse through the window's layout pass.
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ view: some View) {
        host.rootView = AnyView(view)
    }
}

/// Measures SwiftUI rows off-screen with one reusable hosting controller.
@MainActor
final class RowMeasurer {
    static let shared = RowMeasurer()
    private let controller = NSHostingController(rootView: AnyView(EmptyView()))

    func height(of view: some View, width: CGFloat) -> CGFloat {
        controller.rootView = AnyView(view)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return max(1, ceil(size.height))
    }
}

/// The message table. Text laid over a bubble must take the first click,
/// which a table otherwise keeps for row selection.
final class TimelineTableView: NSTableView {
    /// The drawn row under the pointer. One tracking area for the table
    /// stands in for one per cell: AppKit moved every cell's areas and
    /// cursor rects on each frame of a scroll, a fifth of the main thread.
    private weak var hovered: BubbleCell?
    private var tracking: NSTrackingArea?
    private var settle: Task<Void, Never>?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard tracking == nil else { return }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        pointer(at: convert(event.locationInWindow, from: nil))
    }

    /// A click on no message (below the last, or on a day's or a call's
    /// row) puts the cursor back in the composer, as upstream's does.
    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        let onMessage = row >= 0 && view(atColumn: 0, row: row, makeIfNecessary: false) is BubbleCell
        super.mouseDown(with: event)
        if !onMessage { (delegate as? TimelineCellDelegate)?.clickedBesideMessages() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pointer(at: nil)
    }

    /// Rows move under a still pointer while scrolling; which one it is on
    /// is asked again once the scroll rests.
    func scrolled() {
        hovered?.pointerLeft()
        hovered = nil
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(BubbleCell.restDelay))
            guard let self, !Task.isCancelled, let window = self.window, window.isKeyWindow else { return }
            let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            self.pointer(at: self.visibleRect.contains(point) ? point : nil)
        }
    }

    private func pointer(at point: NSPoint?) {
        var cell: BubbleCell?
        if let point {
            let row = row(at: point)
            if row >= 0 { cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? BubbleCell }
        }
        if cell !== hovered {
            hovered?.pointerLeft()
            hovered = cell
        }
        if let cell, let point { cell.pointerMoved(to: cell.convert(point, from: self)) }
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        true
    }
}

public extension NSUserInterfaceItemIdentifier {
    /// The message table, for the shell's benchmark to find.
    static let messageTimeline = NSUserInterfaceItemIdentifier("ZapFastMessageTimeline")
}
