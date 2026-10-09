import AppKit

/// An arc turning on a circle, which eases in and out instead of popping:
/// the busy sign of a voice message's button, a file's download and a
/// picture's download badge, in the colour of whatever it sits on.
nonisolated final class ArcSpinnerLayer: CAShapeLayer {
    /// How far inside the bounds the circle runs.
    nonisolated(unsafe) var inset: CGFloat = 0 {
        didSet { updatePath() }
    }
    nonisolated(unsafe) private(set) var spinning = false

    override init() {
        super.init()
        fillColor = nil
        lineWidth = 2
        lineCap = .round
        strokeEnd = 0.28
        opacity = 0
        actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "strokeColor": NSNull(), "opacity": NSNull(), "transform": NSNull(), "hidden": NSNull()]
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var bounds: CGRect {
        didSet { if bounds != oldValue { updatePath() } }
    }

    private func updatePath() {
        let rect = bounds.insetBy(dx: inset + lineWidth / 2, dy: inset + lineWidth / 2)
        path = rect.width > 0 ? CGPath(ellipseIn: rect, transform: nil) : nil
    }

    func setSpinning(_ on: Bool, animated: Bool) {
        guard on != spinning else { return }
        spinning = on
        if on {
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.byValue = 2 * Double.pi
            turn.duration = 0.9
            turn.repeatCount = .infinity
            add(turn, forKey: "turn")
            let breathe = CABasicAnimation(keyPath: "strokeEnd")
            breathe.fromValue = 0.18
            breathe.toValue = 0.62
            breathe.duration = 0.8
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            add(breathe, forKey: "breathe")
        }
        let target: Float = on ? 1 : 0
        if animated {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = presentation()?.opacity ?? (on ? 0 : 1)
            fade.toValue = target
            fade.duration = on ? 0.2 : 0.14
            add(fade, forKey: "fade")
        } else {
            removeAnimation(forKey: "fade")
        }
        opacity = target
        guard !on else { return }
        // It stops turning once it has faded.
        nonisolated(unsafe) let owner = self
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.15 : 0)) {
            guard !owner.spinning else { return }
            owner.removeAnimation(forKey: "turn")
            owner.removeAnimation(forKey: "breathe")
        }
    }
}

/// A change of symbol or text that cross-fades with a little scale,
/// rather than swapping in a frame.
@MainActor
enum SoftSwap {
    static func fade(_ layer: CALayer, to visible: Bool, animated: Bool) {
        let target: Float = visible ? 1 : 0
        guard animated, layer.opacity != target else {
            layer.removeAnimation(forKey: "softSwap")
            layer.opacity = target
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? (visible ? 0 : 1)
        fade.toValue = target
        fade.duration = visible ? 0.2 : 0.14
        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = visible ? 0.6 : 1
        scale.toValue = visible ? 1 : 0.6
        scale.stiffness = 380
        scale.damping = 22
        scale.duration = visible ? scale.settlingDuration : 0.14
        let group = CAAnimationGroup()
        group.animations = [fade, scale]
        group.duration = max(fade.duration, scale.duration)
        layer.add(group, forKey: "softSwap")
        layer.opacity = target
    }
}
