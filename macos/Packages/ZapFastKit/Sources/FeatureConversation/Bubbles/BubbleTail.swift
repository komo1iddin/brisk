import CoreGraphics
import SwiftUI
import ZapFastDesign

/// A bubble's tail, as WhatsApp draws it on the last message of a run: the
/// bottom corner on the sender's side squared off, with a short hook
/// reaching out of it towards the sender's photo or the window's edge.
nonisolated enum BubbleTail {
    /// How far the hook reaches past the bubble's side.
    static let reach: CGFloat = 5

    /// The piece added to the rounded bubble, in the bubble's coordinates
    /// (top left origin).
    static func path(size: CGSize, fromMe: Bool) -> CGPath {
        let radius = Metrics.bubbleRadius
        let bottom = size.height
        let top = max(0, bottom - radius)
        func x(_ value: CGFloat) -> CGFloat { fromMe ? size.width - value : value }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x(0), y: top))
        // Down the side and out to the hook's point...
        path.addCurve(
            to: CGPoint(x: x(-reach), y: bottom),
            control1: CGPoint(x: x(0), y: bottom - radius * 0.4),
            control2: CGPoint(x: x(-reach * 0.4), y: bottom - 0.8)
        )
        // ...then back along the bottom, past where the corner was rounded.
        path.addCurve(
            to: CGPoint(x: x(radius), y: bottom),
            control1: CGPoint(x: x(-reach * 0.2), y: bottom),
            control2: CGPoint(x: x(radius * 0.4), y: bottom)
        )
        path.addLine(to: CGPoint(x: x(radius), y: top))
        path.closeSubpath()
        return path
    }
}

/// `BubbleTail` for a SwiftUI bubble's background.
nonisolated struct BubbleTailShape: Shape {
    let fromMe: Bool

    func path(in rect: CGRect) -> Path {
        Path(BubbleTail.path(size: rect.size, fromMe: fromMe)).offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
