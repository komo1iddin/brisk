/// The reaction pills under a bubble.

import AppKit
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// The reaction pills under a bubble: who chose each shows on hover, and a
/// click adds our reaction or takes it away, as upstream's pills do.
final class ReactionPillsView: NSView, NSViewToolTipOwner {
    private let drawing = PillsLayer()
    weak var cell: BubbleCell?
    private var pills: [BubbleLayout.Pill] = []

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
        pills = layout.pills
        removeAllToolTips()
        for (index, pill) in pills.enumerated() {
            addToolTip(Self.frame(of: pill), owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
        needsRedraw()
    }

    /// The pill's place in this view, two points in for the shadow.
    private static func frame(of pill: BubbleLayout.Pill) -> CGRect {
        pill.rect.offsetBy(dx: 2, dy: 2)
    }

    private func pill(at point: NSPoint) -> BubbleLayout.Pill? {
        pills.first { Self.frame(of: $0).contains(point) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let index = Int(bitPattern: data) - 1
        guard pills.indices.contains(index), let cell, let id = cell.messageID else { return "" }
        return cell.delegate?.reactionNames(pills[index].value, ofMessage: id) ?? ""
    }

    override func mouseDown(with event: NSEvent) {
        guard let pill = pill(at: convert(event.locationInWindow, from: nil)), let cell, let id = cell.messageID else {
            return super.mouseDown(with: event)
        }
        cell.delegate?.toggleReaction(pill.value, ofMessage: id)
    }

    override func resetCursorRects() {
        for pill in pills { addCursorRect(Self.frame(of: pill), cursor: .pointingHand) }
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

    /// Only the pills take clicks; between them the bubble's row does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return pill(at: convert(point, from: superview)) == nil ? nil : self
    }
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
                    NSColor.separatorColor.setStroke()
                    path.lineWidth = 1
                    path.stroke()
                    pill.emoji.draw()
                    pill.count?.draw()
                }
            }
        }
    }
}
