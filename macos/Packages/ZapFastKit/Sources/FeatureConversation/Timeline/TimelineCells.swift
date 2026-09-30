import AppKit
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

// MARK: - Day separator and unread divider

/// `DaySeparator` and `UnreadSeparator` drawn by Core Animation: a caption
/// in a capsule of the theme's chip colour, centred.
final class ChipCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("TimelineChip")

    private let chip = CALayer()
    private let text = TextLayer()
    private var title: NSAttributedString?
    private var colors: BubbleColors?

    /// The chip's size and the row's height for a title.
    static func measure(_ title: String) -> (text: NSAttributedString, chip: CGSize, rowHeight: CGFloat) {
        let string = TimelineText.line(title, TimelineText.captionMedium, .secondaryLabelColor)
        let size = TimelineText.size(string)
        let chip = CGSize(width: size.width + Metrics.m * 2, height: size.height + Metrics.xs * 2)
        return (string, chip, chip.height + Metrics.s * 2)
    }

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

    func configure(title: String, isHeader: Bool, colors: BubbleColors) {
        let measured = Self.measure(title)
        self.title = measured.text
        self.colors = colors
        text.piece = TextPiece(string: measured.text, rect: CGRect(
            origin: CGPoint(x: Metrics.m, y: Metrics.xs),
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

    /// Set directly rather than in `layout()`, as `TextBubbleCell` does.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { placeChip() }
    }

    private func placeChip() {
        guard let title else { return }
        let size = TimelineText.size(title)
        let chipSize = CGSize(width: size.width + Metrics.m * 2, height: size.height + Metrics.xs * 2)
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
        guard case .message(let message, _) = row else { return NSUserInterfaceItemIdentifier("TimelineHosting") }
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
        // Sized by its mask, not constraints: constraints in scrolled cells
        // send each reuse through the window's layout pass.
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
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        true
    }
}

public extension NSUserInterfaceItemIdentifier {
    /// The message table, for the shell's benchmark to find.
    static let messageTimeline = NSUserInterfaceItemIdentifier("ZapFastMessageTimeline")
}
