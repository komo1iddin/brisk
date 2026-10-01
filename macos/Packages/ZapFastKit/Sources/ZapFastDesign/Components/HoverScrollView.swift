import AppKit

/// A vertical scroll bar that is only a slim knob: no track, no arrows, and
/// no room taken from the content.
@MainActor
public final class SlimScroller: NSScroller {
    private static let thickness: CGFloat = 10
    private static let knobWidth: CGFloat = 4
    private static let shortest: CGFloat = 36
    private static let longest: CGFloat = 84

    override public class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        thickness
    }

    /// The knob is short, as Telegram's: what the content's proportion gives,
    /// held between a floor and a ceiling, so it is no long bar on a short
    /// list and still no speck on a long one. It travels the whole slot.
    override public func rect(for part: NSScroller.Part) -> NSRect {
        let rect = super.rect(for: part)
        guard part == .knob, rect.height > 0 else { return rect }
        let slot = super.rect(for: .knobSlot)
        let length = min(max(rect.height, Self.shortest), min(Self.longest, slot.height))
        let travelled = slot.height - rect.height
        let along = travelled > 0 ? (rect.minY - slot.minY) / travelled : 0
        return NSRect(x: rect.minX, y: slot.minY + (slot.height - length) * along, width: rect.width, height: length)
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard usableParts != .noScrollerParts else { return }
        drawKnob()
    }

    override public func drawKnob() {
        let knob = rect(for: .knob)
        let inset = NSRect(
            x: knob.maxX - Self.knobWidth - 2,
            y: knob.minY + 2,
            width: Self.knobWidth,
            height: max(knob.height - 4, Self.knobWidth)
        )
        // Resolved at draw time, so it follows the appearance.
        let pressed = hitPart == .knob
        NSColor.labelColor.withAlphaComponent(pressed ? 0.5 : 0.32).setFill()
        NSBezierPath(roundedRect: inset, xRadius: Self.knobWidth / 2, yRadius: Self.knobWidth / 2).fill()
    }
}

/// A scroll view whose bar is slim, floats over the content, and shows only
/// while the pointer is over the view, as in WhatsApp's chat list.
@MainActor
public final class HoverScrollView: NSScrollView {
    private var hovering = false

    override public init(frame: NSRect) {
        super.init(frame: frame)
        verticalScroller = SlimScroller()
        // The system's setting may be to always show bars, which would draw
        // a track beside the content; this bar draws itself.
        super.scrollerStyle = .legacy
        hasVerticalScroller = true
        autohidesScrollers = true
        verticalScroller?.alphaValue = 0
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override public var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .legacy }
    }

    /// The bar floats over the content instead of narrowing it.
    override public func tile() {
        super.tile()
        contentView.frame = bounds
        if let scroller = verticalScroller, subviews.last !== scroller {
            addSubview(scroller, positioned: .above, relativeTo: nil)
        }
    }

    /// The knob shows what is on screen of what there is: AppKit measures a
    /// scroll view that is inset (a chat list under its toolbar) with the
    /// insets counted as content on one side only, which stretches it.
    override public func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        guard clipView === contentView, let scroller = verticalScroller, let document = documentView else { return }
        let insets = clipView.contentInsets
        let visible = clipView.bounds.height - insets.top - insets.bottom
        let total = document.frame.height
        guard visible > 0, total > visible else { return }
        scroller.knobProportion = visible / total
        scroller.doubleValue = min(1, max(0, (clipView.bounds.minY + insets.top) / (total - visible)))
    }

    override public func mouseEntered(with event: NSEvent) {
        setBarVisible(true)
    }

    override public func mouseExited(with event: NSEvent) {
        setBarVisible(false)
    }

    /// Shows the bar as if the pointer were over the view.
    public func setBarVisible(_ visible: Bool) {
        hovering = visible
        guard let scroller = verticalScroller else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0 : 0.18
            scroller.animator().alphaValue = visible ? 1 : 0
        }
    }

    /// Whether the bar is showing now.
    public var barIsVisible: Bool { hovering }
}
