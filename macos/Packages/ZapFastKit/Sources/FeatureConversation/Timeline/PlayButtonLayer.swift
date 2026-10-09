import AppKit

/// A voice message's round button, drawn as shapes so it moves rather than
/// blinks: the glyph (play, pause, a download arrow) is cut out of a disc
/// and morphs from one to the next, and while the clip downloads or
/// decodes it folds away for an arc that turns inside the disc.
///
/// Every glyph is two four-point outlines, so any one morphs into any
/// other; "none" is both folded into the centre.
nonisolated final class PlayButtonLayer: CALayer {
    enum Glyph: Equatable {
        case play, pause, download, none
    }

    private let disc = CAShapeLayer()
    private let ring = ArcSpinnerLayer()
    private(set) var glyph: Glyph = .play

    override init() {
        super.init()
        disc.fillRule = .evenOdd
        disc.actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "fillColor": NSNull(), "transform": NSNull()]
        ring.lineWidth = 2.2
        addSublayer(disc)
        addSublayer(ring)
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func action(forKey event: String) -> (any CAAction)? { nil }

    override func layoutSublayers() {
        super.layoutSublayers()
        disc.frame = bounds
        ring.frame = bounds
        disc.path = Self.path(glyph, in: bounds)
        ring.inset = (min(bounds.width, bounds.height) - 20) / 2
    }

    /// The disc's colour, and the colour behind it, which the turning arc
    /// is drawn in (the glyph is a hole and needs none).
    func setColors(_ color: CGColor, background: CGColor) {
        disc.fillColor = color
        ring.strokeColor = background
    }

    /// Shows `glyph`, morphing from the one shown when `animated`.
    func show(_ new: Glyph, animated: Bool) {
        guard new != glyph else { return }
        let old = glyph
        glyph = new
        let path = Self.path(new, in: bounds)
        if animated {
            let morph = CABasicAnimation(keyPath: "path")
            morph.fromValue = disc.presentation()?.path ?? Self.path(old, in: bounds)
            morph.toValue = path
            if old == .none {
                // Out of the centre, with a little overshoot.
                morph.duration = 0.32
                morph.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.45, 0.55, 1)
            } else {
                morph.duration = new == .none ? 0.16 : 0.22
                morph.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            }
            disc.add(morph, forKey: "morph")
        } else {
            disc.removeAnimation(forKey: "morph")
        }
        disc.path = path
    }

    /// The arc turning inside the disc, easing in and out.
    func setSpinning(_ on: Bool, animated: Bool) {
        ring.setSpinning(on, animated: animated)
    }

    // MARK: Shapes

    /// The disc with the glyph's two outlines cut out of it.
    static func path(_ glyph: Glyph, in bounds: CGRect) -> CGPath {
        let path = CGMutablePath()
        let side = min(bounds.width, bounds.height) - 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        path.addEllipse(in: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side))
        let unit = side / 30
        for quad in outlines(glyph) {
            path.addLines(between: quad.map { CGPoint(x: center.x + $0.x * unit, y: center.y + $0.y * unit) })
            path.closeSubpath()
        }
        return path
    }

    /// Each glyph's two outlines on a 30-point disc, around its centre,
    /// y down, each listed top left, top right, bottom right, bottom left.
    static func outlines(_ glyph: Glyph) -> [[CGPoint]] {
        switch glyph {
        case .play:
            // A triangle, cut down its middle, a little right of centre as
            // a triangle looks centred.
            let (left, middle, right, half) = (-4.5, 1.5, 7.5, 7.5)
            let edge = half * (right - middle) / (right - left)
            return [
                [CGPoint(x: left, y: -half), CGPoint(x: middle, y: -edge), CGPoint(x: middle, y: edge), CGPoint(x: left, y: half)],
                [CGPoint(x: middle, y: -edge), CGPoint(x: right, y: 0), CGPoint(x: right, y: 0), CGPoint(x: middle, y: edge)],
            ]
        case .pause:
            let (width, gap, half) = (3.6, 2.2, 6.8)
            return [
                [CGPoint(x: -gap - width, y: -half), CGPoint(x: -gap, y: -half), CGPoint(x: -gap, y: half), CGPoint(x: -gap - width, y: half)],
                [CGPoint(x: gap, y: -half), CGPoint(x: gap + width, y: -half), CGPoint(x: gap + width, y: half), CGPoint(x: gap, y: half)],
            ]
        case .download:
            // A shaft and the head below it.
            return [
                [CGPoint(x: -1.6, y: -7.5), CGPoint(x: 1.6, y: -7.5), CGPoint(x: 1.6, y: 1), CGPoint(x: -1.6, y: 1)],
                [CGPoint(x: -6, y: 0), CGPoint(x: 6, y: 0), CGPoint(x: 0, y: 6.5), CGPoint(x: 0, y: 6.5)],
            ]
        case .none:
            return Array(repeating: Array(repeating: .zero, count: 4), count: 2)
        }
    }
}
