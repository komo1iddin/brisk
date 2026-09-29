import AVFoundation
import Foundation
import Observation

/// Plays one video inside its message at a time, as upstream does
/// (`src/video.rs`). AVFoundation opens WhatsApp's MP4s (H.264 or HEVC,
/// AAC) itself, so nothing is handed to the system player. The bubble
/// shows `player` in an `AVPlayerView` while its message is current.
@Observable
public final class VideoPlayback {
    public private(set) var current: MessageKey?

    @ObservationIgnored public let player = AVPlayer()
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    public init() {
        player.actionAtItemEnd = .pause
        // A video that ends goes back to its poster, as on the phone.
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let ended = ObjectIdentifier(notification.object as AnyObject)
            MainActor.assumeIsolated {
                guard let self, let item = self.player.currentItem, ObjectIdentifier(item) == ended else { return }
                self.stop()
            }
        }
    }

    public func isCurrent(_ key: MessageKey) -> Bool {
        current == key
    }

    /// Starts `url` in its message, or pauses and resumes it when current.
    public func toggle(_ key: MessageKey, url: URL) {
        if current == key {
            if player.timeControlStatus == .paused { player.play() } else { player.pause() }
            return
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        current = key
        player.play()
    }

    /// Pauses without leaving the message (it scrolled out of view).
    public func pause(_ key: MessageKey) {
        guard current == key else { return }
        player.pause()
    }

    public func stop() {
        guard current != nil else { return }
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
    }
}
