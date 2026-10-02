import AppKit
import AVKit
import ZapFastCore
import ZapFastDesign

/// A photo, video, GIF or sticker in a drawn bubble, as `VisualMedia` shows
/// it: the picture at its shape (the sender's preview until the file is
/// here), a play button on a video, its length, "GIF", and a download badge
/// until the file is here. A click opens it; a downloaded file drags out.
///
/// Heavier things wait: a GIF loops and an animated sticker moves only
/// once the pointer rests on it, and a video's player is made only while it
/// plays in place.
final class PictureView: AttachmentView {
    private(set) var pictureLayout: BubbleLayout.PictureLayout?

    private let picture = CALayer()
    /// "photo" and the like, over the grey ground while nothing is decoded.
    private let placeholder = SymbolLayer()
    private let glyph = SymbolLayer()
    private let durationCapsule = CALayer()
    private let durationText = TextLayer()
    private let gifCapsule = CALayer()
    private let gifText = TextLayer()
    private let badge = DownloadBadgeView()
    private var player: PlayerView.WindowedPlayerView?
    private var looping: LoopingVideo.LoopingView?
    /// A Lottie sticker's player, made once its file is here.
    private var lottie: LottieStickerView?
    private var lottieFile: String?

    private var image: CGImage?
    private var hasImage: Bool { image != nil }
    /// The bubble's text colour, which the grey ground and its symbol are
    /// made from, as SwiftUI's `.quaternary` and `.secondary` are.
    private var textColor = NSColor.labelColor
    private var loads = 0
    private var download: DownloadState?
    private(set) var moving = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        picture.contentsGravity = .resizeAspectFill
        picture.masksToBounds = true
        for capsule in [durationCapsule, gifCapsule] {
            capsule.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        }
        durationCapsule.addSublayer(durationText)
        gifCapsule.addSublayer(gifText)
        for sublayer in [picture, placeholder, glyph, gifCapsule, durationCapsule] {
            layer?.addSublayer(sublayer)
        }
        for sublayer in [picture, placeholder, glyph, gifCapsule, durationCapsule, durationText, gifText] {
            sublayer.actions = Self.noActions
        }
        glyph.configure(
            symbol: "play.circle.fill", pointSize: 40, weight: .regular,
            palette: [.white, NSColor.black.withAlphaComponent(0.35)]
        )
        addSubview(badge)
    }

    private static let noActions: [String: any CAAction] = [
        "bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "hidden": NSNull(),
        "backgroundColor": NSNull(), "cornerRadius": NSNull(), "frame": NSNull(),
    ]

    // MARK: Configuring

    func configure(_ layout: BubbleLayout.PictureLayout, messageID: String, color: NSColor) {
        let sameMessage = messageID == self.messageID
        let same = sameMessage && layout.picture == pictureLayout?.picture && layout.points == pictureLayout?.points
        if !sameMessage {
            setMoving(false)
            setPlaying(false)
        }
        self.messageID = messageID
        pictureLayout = layout
        textColor = color
        let bounds = CGRect(origin: .zero, size: layout.frame.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = layout.circle ? bounds.width / 2 : layout.cornerRadius
        // A continuous curve of half the side leaves a hairline at the top
        // and bottom of a circle.
        layer?.cornerCurve = layout.circle ? .circular : .continuous
        picture.frame = bounds
        placeholder.frame = bounds
        glyph.frame = layout.glyph ?? .zero
        if let duration = layout.duration {
            durationCapsule.frame = duration.capsule
            durationCapsule.cornerRadius = duration.capsule.height / 2
            durationText.frame = CGRect(origin: CGPoint(x: 6, y: 2), size: duration.text.rect.size)
            durationText.piece = TextPiece(string: duration.text.string, rect: CGRect(origin: .zero, size: duration.text.rect.size))
            durationText.setNeedsDisplay()
        }
        if let gif = layout.gif {
            gifCapsule.frame = gif.capsule
            gifCapsule.cornerRadius = gif.capsule.height / 2
            gifText.frame = CGRect(origin: CGPoint(x: 6, y: 2), size: gif.text.rect.size)
            gifText.piece = TextPiece(string: gif.text.string, rect: CGRect(origin: .zero, size: gif.text.rect.size))
            gifText.setNeedsDisplay()
        }
        CATransaction.commit()
        player?.frame = bounds
        looping?.frame = bounds
        lottie?.frame = bounds
        if !same { loadImage(keepingShown: sameMessage) }
        refreshLottie()
        placeholder.configure(
            symbol: Self.placeholderSymbol(layout.picture.kind), pointSize: 26, weight: .regular,
            palette: [TimelineText.faded(color, 0.55)]
        )
        refreshOverlays()
        applyAppearance()
    }

    /// The download's state, while the file is not here.
    func setDownload(_ state: DownloadState?) {
        download = state
        refreshOverlays()
    }

    private func refreshOverlays() {
        guard let layout = pictureLayout else { return }
        let picture = layout.picture
        let here = picture.path != nil
        let playing = player != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholder.isHidden = hasImage || lottie?.isReady == true || !(here || picture.isSticker)
        glyph.isHidden = layout.glyph == nil || playing || !here
        gifCapsule.isHidden = layout.gif == nil || !here || moving
        durationCapsule.isHidden = layout.duration == nil || playing
        CATransaction.commit()
        badge.isHidden = here || picture.isSticker
        if !badge.isHidden {
            badge.show(download, bytes: picture.bytes)
            let size = badge.fittingSize
            badge.frame = CGRect(
                x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                width: size.width, height: size.height
            )
        }
    }

    private static func placeholderSymbol(_ kind: BubbleSource.Picture.Kind) -> String {
        switch kind {
        case .photo: "photo"
        case .video, .gif, .roundVideo: "play.circle.fill"
        case .sticker, .animatedSticker: "face.smiling"
        }
    }

    func refreshColors() {
        applyAppearance()
        placeholder.setNeedsDisplay()
        glyph.setNeedsDisplay()
    }

    private func applyAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // `.quaternary` behind a picture not decoded yet.
            picture.backgroundColor = hasImage || lottie?.isReady == true ? nil : TimelineText.faded(textColor, 0.12).cgColor
        }
        for layer in [placeholder, glyph] { layer.appearance = effectiveAppearance }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [placeholder, glyph, durationText, gifText] as [CALayer] {
            layer.contentsScale = scale
            layer.setNeedsDisplay()
        }
    }

    // MARK: A Lottie sticker

    /// The player of a Lottie sticker whose file is here; none for anything
    /// else. It shows the first frame at once and moves with `setMoving`.
    private func refreshLottie() {
        guard let layout = pictureLayout, layout.picture.isLottie, let path = layout.picture.path else {
            dropLottie()
            return
        }
        guard lottieFile != path else { return }
        dropLottie()
        lottieFile = path
        let view = LottieStickerView(frame: bounds)
        addSubview(view, positioned: .below, relativeTo: badge)
        lottie = view
        Task { [weak self, weak view] in
            guard let view, await view.load(file: URL(filePath: path)) else { return }
            guard let self, self.lottie === view else { return }
            if self.moving { view.setPlaying(true) }
            self.applyAppearance()
            self.refreshOverlays()
        }
    }

    private func dropLottie() {
        lottie?.removeFromSuperview()
        lottie = nil
        lottieFile = nil
    }

    // MARK: The picture

    /// The file when it is an image that is here, else the sender's
    /// preview, decoded off the main actor at the size drawn; one decoded
    /// before shows at once. The same message keeps what it shows until
    /// then: its preview while the file that came is decoded, the picture
    /// at the old size while a new one is.
    private func loadImage(keepingShown: Bool) {
        guard let layout = pictureLayout, let id = messageID else { return }
        loads += 1
        let load = loads
        let picture = layout.picture
        let points = layout.points
        let file = picture.path.flatMap { picture.mime.hasPrefix("image") ? URL(filePath: $0) : nil }
        let key = "thumb-\(id)"
        if let file, let image = Thumbnails.cached(file, points: points) {
            show(image)
            return
        }
        if file == nil, picture.thumbnail != nil, let image = Thumbnails.cached(key: key, points: points) {
            show(image)
            return
        }
        if !keepingShown { show(nil) }
        let thumbnail = picture.thumbnail
        Task { [weak self] in
            var image: NSImage?
            if let file {
                image = await Thumbnails.load(file, points: points)
            } else if let thumbnail {
                image = await Thumbnails.load(thumbnail, key: key, points: points)
            }
            guard let self, self.loads == load, let image else { return }
            self.show(image)
        }
    }

    private func show(_ image: NSImage?) {
        self.image = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = self.image
        CATransaction.commit()
        applyAppearance()
        refreshOverlays()
    }

    /// The picture as it shows, for dragging.
    override var dragImage: NSImage? {
        image.map { NSImage(cgImage: $0, size: bounds.size) }
    }

    // MARK: Moving and playing

    /// A GIF loops and an animated sticker moves while the pointer rests
    /// on it in the key window, never with Reduce Motion on.
    func setMoving(_ on: Bool) {
        let on = on && pictureLayout?.picture.path != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard on != moving, let layout = pictureLayout else { return }
        moving = on
        switch layout.picture.kind {
        case .gif:
            if on, let path = layout.picture.path {
                let view = LoopingVideo.LoopingView(url: URL(filePath: path))
                view.frame = bounds
                addSubview(view, positioned: .below, relativeTo: badge)
                looping = view
            } else {
                looping?.stop()
                looping?.removeFromSuperview()
                looping = nil
            }
        case .animatedSticker:
            if layout.picture.isLottie {
                lottie?.setPlaying(on)
            } else if on, let path = layout.picture.path {
                let load = loads
                Task { [weak self] in
                    guard let frames = await AnimatedFrames.load(URL(filePath: path), points: layout.points),
                          let self, self.loads == load, self.moving else { return }
                    self.picture.add(frames.contentsAnimation(), forKey: "frames")
                }
            } else {
                picture.removeAnimation(forKey: "frames")
            }
        case .photo, .video, .sticker, .roundVideo:
            break
        }
        refreshOverlays()
    }

    /// The system player over the picture while this message's video plays
    /// in place; a round one keeps its circle and shows only a play button.
    func setPlaying(_ on: Bool, player wanted: AVPlayer? = nil) {
        if on, let wanted, let layout = pictureLayout {
            let view = player ?? PlayerView.WindowedPlayerView()
            view.controlsStyle = layout.circle ? .minimal : .inline
            view.showsFullScreenToggleButton = !layout.circle
            view.allowsPictureInPicturePlayback = true
            view.videoGravity = layout.circle ? .resizeAspectFill : .resizeAspect
            view.frame = bounds
            if view.superview == nil { addSubview(view, positioned: .below, relativeTo: badge) }
            view.wanted = wanted
            player = view
        } else if let view = player {
            view.wanted = nil
            view.removeFromSuperview()
            player = nil
        }
        refreshOverlays()
    }
}

/// The badge over media not downloaded yet: its size and an arrow, a
/// spinner while it comes, "Retry" after a failure, as `DownloadBadge`.
final class DownloadBadgeView: NSView {
    private let capsule = CALayer()
    private let icon = SymbolLayer()
    private let text = TextLayer()
    private let spinner = NSProgressIndicator()
    private var shown: (state: DownloadState?, bytes: UInt64)?
    private var content = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        capsule.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        layer?.addSublayer(capsule)
        layer?.addSublayer(icon)
        layer?.addSublayer(text)
        for sublayer in [capsule, icon, text] as [CALayer] {
            sublayer.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "contents": NSNull()]
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        // White on the dark capsule.
        spinner.appearance = NSAppearance(named: .darkAqua)
        addSubview(spinner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override var fittingSize: NSSize { content }

    func show(_ state: DownloadState?, bytes: UInt64) {
        if let shown, shown.state == state, shown.bytes == bytes { return }
        shown = (state, bytes)
        let padding = CGSize(width: Metrics.s, height: Metrics.xs)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch state {
        case .downloading:
            icon.isHidden = true
            text.isHidden = true
            let size: CGFloat = 16
            content = CGSize(width: size + padding.width * 2, height: size + padding.height * 2)
            spinner.frame = CGRect(x: padding.width, y: padding.height, width: size, height: size)
            spinner.startAnimation(nil)
        case .failed, nil:
            spinner.stopAnimation(nil)
            let title = if case .failed = state {
                String(localized: "Retry")
            } else {
                bytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) : String(localized: "Download")
            }
            let string = TimelineText.line(title, TimelineText.captionMedium, .white)
            let textSize = TimelineText.size(string)
            let iconSize = CGSize(width: 13, height: textSize.height)
            let spacing: CGFloat = 4
            content = CGSize(
                width: padding.width * 2 + iconSize.width + spacing + textSize.width,
                height: padding.height * 2 + textSize.height
            )
            icon.isHidden = false
            text.isHidden = false
            icon.configure(
                symbol: state == nil ? "arrow.down.circle.fill" : "arrow.clockwise",
                pointSize: TimelineText.captionMedium.pointSize, weight: .medium, palette: [.white]
            )
            icon.frame = CGRect(origin: CGPoint(x: padding.width, y: padding.height), size: iconSize)
            text.frame = CGRect(origin: CGPoint(x: padding.width + iconSize.width + spacing, y: padding.height), size: textSize)
            text.piece = TextPiece(string: string, rect: CGRect(origin: .zero, size: textSize))
            text.setNeedsDisplay()
        }
        capsule.frame = CGRect(origin: .zero, size: content)
        capsule.cornerRadius = content.height / 2
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [icon, text] as [CALayer] {
            layer.contentsScale = scale
            layer.setNeedsDisplay()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
