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

    /// The knob is short, as Telegram's: the proportion of what is on screen,
    /// held between a floor and a ceiling, so it is no long bar on a short list
    /// and no speck on a long one. Where it sits is read from the scroll view
    /// itself, offset and insets together, each time it is drawn: the values
    /// AppKit hands the scroller differ between ways of scrolling when the
    /// view is inset (a chat list under its toolbar).
    override public func rect(for part: NSScroller.Part) -> NSRect {
        let rect = super.rect(for: part)
        guard part == .knob, rect.height > 0, let scrollView = superview as? NSScrollView,
              let document = scrollView.documentView else { return rect }
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        let visible = clip.bounds.height - insets.top - insets.bottom
        let total = document.frame.height
        guard visible > 0, total > visible else { return rect }
        let slot = super.rect(for: .knobSlot)
        let length = min(max(visible / total * slot.height, Self.shortest), min(Self.longest, slot.height))
        let along = min(1, max(0, (clip.bounds.minY + insets.top) / (total - visible)))
        // The slot's own direction: the knob starts at its top when the
        // scroller is flipped, and at its bottom when it is not.
        let offset = (slot.height - length) * (isFlipped ? along : 1 - along)
        return NSRect(x: rect.minX, y: slot.minY + offset, width: rect.width, height: length)
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
        contentView = FullWidthClipView()
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

    /// The bar floats over the content instead of narrowing it: the clip
    /// view keeps the full width (`FullWidthClipView`).
    override public func tile() {
        super.tile()
        if let scroller = verticalScroller, subviews.last !== scroller {
            addSubview(scroller, positioned: .above, relativeTo: nil)
        }
    }

    override public func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        verticalScroller?.needsDisplay = true
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

/// The clip view of a `HoverScrollView`, always as wide as the scroll view.
/// AppKit tiles a legacy scroll bar's room out of the clip on every frame of
/// a scroll; narrowing the clip and widening it again each time resized the
/// document twice, and each resize put the scroll back inside the content:
/// a reader pulling past the end of a chat was snapped back and thrown out
/// again, frame after frame.
private final class FullWidthClipView: NSClipView {
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(superview is HoverScrollView ? NSPoint(x: 0, y: newOrigin.y) : newOrigin)
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard let scrollView = superview as? HoverScrollView else { return super.setFrameSize(newSize) }
        super.setFrameSize(NSSize(width: scrollView.bounds.width, height: newSize.height))
    }
}
