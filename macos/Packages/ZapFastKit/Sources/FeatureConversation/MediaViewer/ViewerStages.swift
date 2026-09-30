import AppKit
import AVKit
import SwiftUI
import VisionKit

/// Zoom commands from the keyboard, and whether the photo is zoomed in.
@MainActor
final class PhotoZoom {
    fileprivate weak var view: ZoomingPhotoView?

    var isZoomed: Bool { (view?.magnification ?? 1) > 1.01 }

    func zoomIn() { view?.zoom(by: 1.5) }
    func zoomOut() { view?.zoom(by: 1 / 1.5) }
    func reset() { view?.zoom(to: 1, at: nil) }
}

/// A photo that fits the stage and zooms as the Mac's own viewers do:
/// pinch, a double-click (or the trackpad's smart zoom) at a point, and
/// scrolling around once zoomed. Live Text lies over it, so text in the
/// picture can be selected, copied and looked up, and codes opened. A
/// two-finger swipe while it fits steps to the next or previous photo.
struct ZoomablePhoto: NSViewRepresentable {
    let url: URL
    let zoom: PhotoZoom
    let swipe: (_ forward: Bool) -> Void

    func makeNSView(context: Context) -> ZoomingPhotoView {
        let view = ZoomingPhotoView()
        zoom.view = view
        view.onSwipe = swipe
        view.show(url)
        return view
    }

    func updateNSView(_ view: ZoomingPhotoView, context: Context) {
        zoom.view = view
        view.onSwipe = swipe
        if view.url != url { view.show(url) }
    }
}

final class ZoomingPhotoView: NSScrollView {
    private(set) var url: URL?
    var onSwipe: (Bool) -> Void = { _ in }

    private let imageView = NSImageView()
    private let overlay = ImageAnalysisOverlayView()
    private var analysis: Task<Void, Never>?
    private var swipeDistance: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        drawsBackground = false
        contentView.drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        minMagnification = 1
        maxMagnification = 8
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        documentView = imageView

        overlay.trackingImageView = imageView
        overlay.autoresizingMask = [.width, .height]
        imageView.addSubview(overlay)

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleClick.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClick)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ url: URL) {
        self.url = url
        let image = NSImage(contentsOf: url)
        imageView.image = image
        overlay.analysis = nil
        magnification = 1
        fit()
        analysis?.cancel()
        guard let image, ImageAnalyzer.isSupported else { return }
        analysis = Task { [weak self] in
            let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode, .visualLookUp])
            guard let result = try? await ImageAnalyzer().analyze(image, orientation: .up, configuration: configuration),
                  !Task.isCancelled, let self, self.url == url else { return }
            self.overlay.analysis = result
            self.overlay.preferredInteractionTypes = .automatic
        }
    }

    override func layout() {
        super.layout()
        fit()
    }

    /// The picture at the size that fits the stage when not zoomed: never
    /// enlarged past its own pixels beyond twice, which keeps a small
    /// picture from turning to mush.
    private func fit() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        let bounds = frame.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let pixels = image.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
        let natural = pixels.width > 0 ? CGSize(width: pixels.width / 2, height: pixels.height / 2) : image.size
        let scale = min(bounds.width / natural.width, bounds.height / natural.height, 2)
        let size = CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
        if imageView.frame.size != size {
            imageView.frame = CGRect(origin: .zero, size: size)
            overlay.frame = imageView.bounds
        }
    }

    @objc private func toggleZoom(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: imageView)
        zoom(to: magnification > 1.01 ? 1 : 2.5, at: point)
    }

    func zoom(by factor: CGFloat) {
        let center = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        zoom(to: magnification * factor, at: center)
    }

    func zoom(to level: CGFloat, at point: NSPoint?) {
        let level = min(max(level, minMagnification), maxMagnification)
        let center = point ?? NSPoint(x: imageView.bounds.midX, y: imageView.bounds.midY)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setMagnification(level, centeredAt: center)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                animator().setMagnification(level, centeredAt: center)
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // While the photo fits, a horizontal two-finger swipe turns pages.
        guard magnification <= 1.01, event.hasPreciseScrollingDeltas else {
            super.scrollWheel(with: event)
            return
        }
        switch event.phase {
        case .began:
            swipeDistance = 0
        case .changed:
            swipeDistance += event.scrollingDeltaX
        case .ended:
            if abs(swipeDistance) > 80 { onSwipe(swipeDistance < 0) }
            swipeDistance = 0
        default:
            break
        }
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) { super.scrollWheel(with: event) }
    }
}

/// Keeps a document smaller than the view in its middle.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

/// A video with the Mac's floating controls: the scrubber, speed, Picture
/// in Picture, full screen, and Live Text in a paused frame.
struct ViewerVideo: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.allowsVideoFrameAnalysis = true
        view.speeds = AVPlaybackSpeed.systemDefaultSpeeds
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
