import AppKit
import ZapFastDesign

/// A person's photo in a circle, or their initials on their colour while
/// there is none, as `AvatarView` draws them: layers for a drawn cell to
/// hold (the voice player's side, a group sender beside their messages).
@MainActor
final class AvatarLayers {
    let layer = CAGradientLayer()
    private let image = CALayer()
    private let initials = TextLayer()
    private var source: AvatarSource?
    private var loads = 0

    init() {
        layer.masksToBounds = true
        image.contentsGravity = .resizeAspectFill
        layer.addSublayer(image)
        layer.addSublayer(initials)
        for sublayer in [layer, image, initials] as [CALayer] {
            sublayer.actions = [
                "bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "hidden": NSNull(),
                "colors": NSNull(), "cornerRadius": NSNull(),
            ]
        }
    }

    /// Whose photo, at `frame` in the holder's layer. The photo itself
    /// comes with `show`.
    func configure(personID: String, name: String, frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        layer.cornerRadius = frame.width / 2
        image.frame = CGRect(origin: .zero, size: frame.size)
        let colors = [AppKitPalette.sender(personID).blended(withFraction: 0.12, of: .white), AppKitPalette.sender(personID)]
        layer.colors = colors.compactMap { $0?.cgColor }
        let font = NSFont.systemFont(ofSize: frame.width * 0.38, weight: .semibold).rounded
        let string = TimelineText.line(AvatarView.initials(name), font, .white)
        let size = TimelineText.size(string)
        initials.frame = CGRect(
            x: ((frame.width - size.width) / 2).rounded(), y: ((frame.height - size.height) / 2).rounded(),
            width: size.width, height: size.height
        )
        initials.piece = TextPiece(string: string, rect: CGRect(origin: .zero, size: size))
        CATransaction.commit()
        initials.setNeedsDisplay()
    }

    /// The photo, once there is one; the initials until then.
    func show(url: URL?, version: Int) {
        let new = AvatarSource(url: url, version: version)
        guard new != source else { return }
        source = new
        loads += 1
        let load = loads
        guard let url else {
            showImage(nil)
            return
        }
        let points = max(layer.bounds.width, 1)
        if let cached = Thumbnails.cached(url, points: points) {
            showImage(cached)
            return
        }
        Task { [weak self] in
            let image = await Thumbnails.load(url, points: points)
            guard let self, self.loads == load else { return }
            self.showImage(image)
        }
    }

    func setScale(_ scale: CGFloat) {
        initials.contentsScale = scale
        initials.setNeedsDisplay()
    }

    private func showImage(_ picture: NSImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image.contents = picture?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        initials.isHidden = picture != nil
        CATransaction.commit()
    }
}

private extension NSFont {
    /// The same font in the rounded design, as `.rounded` in SwiftUI.
    var rounded: NSFont {
        fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? self
    }
}
