import AVKit
import SwiftUI

/// A video in the system's player view: inline controls, full screen, and
/// Picture in Picture. The player is attached only once the view is in a
/// window, so off-screen measuring does not render it.
public struct PlayerView: NSViewRepresentable {
    private let player: AVPlayer
    private let fill: Bool
    private let minimal: Bool

    /// `fill` crops to the frame; `minimal` shows only a play button in the
    /// middle (a round video message has no room for a scrubber).
    public init(player: AVPlayer, fill: Bool = false, minimal: Bool = false) {
        self.player = player
        self.fill = fill
        self.minimal = minimal
    }

    public func makeNSView(context: Context) -> WindowedPlayerView {
        let view = WindowedPlayerView()
        view.controlsStyle = minimal ? .minimal : .inline
        view.showsFullScreenToggleButton = !minimal
        view.allowsPictureInPicturePlayback = true
        view.wanted = player
        return view
    }

    public func updateNSView(_ view: WindowedPlayerView, context: Context) {
        view.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        view.wanted = player
    }

    public static func dismantleNSView(_ view: WindowedPlayerView, coordinator: ()) {
        view.player = nil
    }

    public final class WindowedPlayerView: AVPlayerView {
        var wanted: AVPlayer? {
            didSet { attach() }
        }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        private func attach() {
            let player = window == nil ? nil : wanted
            if self.player !== player { self.player = player }
        }
    }
}

/// A short silent video looping in place (a GIF), for as long as it shows.
public struct LoopingVideo: NSViewRepresentable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func makeNSView(context: Context) -> LoopingView {
        LoopingView(url: url)
    }

    public func updateNSView(_ view: LoopingView, context: Context) {
        view.load(url)
    }

    public static func dismantleNSView(_ view: LoopingView, coordinator: ()) {
        view.stop()
    }

    public final class LoopingView: NSView {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var url: URL?

        init(url: URL) {
            super.init(frame: .zero)
            wantsLayer = true
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            self.layer = layer
            player.isMuted = true
            load(url)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        func load(_ url: URL) {
            guard url != self.url else { return }
            self.url = url
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            player.play()
        }

        func stop() {
            player.pause()
            looper = nil
            player.removeAllItems()
        }

        public override func hitTest(_ point: NSPoint) -> NSView? {
            // Clicks belong to the bubble underneath.
            nil
        }
    }
}
