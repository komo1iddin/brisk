import Foundation
import Synchronization

/// The other side's audio between the bridge, which writes a 60 ms frame at
/// a time as the network brings it, and the speaker, which reads a few
/// milliseconds at a time on the render thread.
///
/// It waits for a little audio before it plays and again after it runs dry,
/// so uneven arrival does not chop every word, and it drops the oldest audio
/// once too much has queued, so a burst never leaves the call lagging.
nonisolated public final class PlayoutBuffer: Sendable {
    /// Samples held before playing starts: two frames, 120 ms.
    public static let prime = 1920
    /// Most samples held; older ones are dropped to keep up. 300 ms.
    public static let limit = 4800

    private struct Ring {
        var storage = [Float](repeating: 0, count: PlayoutBuffer.limit)
        var start = 0
        var count = 0
        var playing = false
    }

    private let ring = Mutex(Ring())

    public init() {}

    /// Samples waiting to be played.
    public var queued: Int { ring.withLock { $0.count } }

    /// Whether it is playing rather than waiting for enough audio.
    public var isPlaying: Bool { ring.withLock { $0.playing } }

    public func write(_ samples: [Int16]) {
        ring.withLock { ring in
            let capacity = ring.storage.count
            for sample in samples.suffix(capacity) {
                if ring.count == capacity {
                    ring.start = (ring.start + 1) % capacity
                    ring.count -= 1
                }
                ring.storage[(ring.start + ring.count) % capacity] = Float(sample) / 32768
                ring.count += 1
            }
        }
    }

    /// Fills `frames` samples at `output`, with silence where there is no audio.
    public func read(into output: UnsafeMutablePointer<Float>, frames: Int) {
        ring.withLock { ring in
            if !ring.playing {
                guard ring.count >= Self.prime else {
                    output.update(repeating: 0, count: frames)
                    return
                }
                ring.playing = true
            }
            let capacity = ring.storage.count
            let available = min(frames, ring.count)
            for index in 0 ..< available {
                output[index] = ring.storage[(ring.start + index) % capacity]
            }
            ring.start = (ring.start + available) % capacity
            ring.count -= available
            if available < frames {
                (output + available).update(repeating: 0, count: frames - available)
                ring.playing = false
            }
        }
    }

    public func reset() {
        ring.withLock { $0 = Ring() }
    }
}
