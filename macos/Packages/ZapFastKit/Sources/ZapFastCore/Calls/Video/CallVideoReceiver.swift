import Synchronization
import ZapFastBridge

/// The bridge calls from its media thread. Inactive/locked/retired calls
/// must not keep scheduling a decoder or orientation callbacks.
nonisolated final class CallVideoReceiver: Sendable {
    private let enabled = Atomic<Bool>(false)
    private let renderer: VideoRenderer
    init(_ renderer: VideoRenderer) { self.renderer = renderer }
    func setEnabled(_ value: Bool) { enabled.store(value, ordering: .releasing) }
    func receive(_ frame: VideoFrameInfo) {
        guard enabled.load(ordering: .acquiring) else { return }
        renderer.enqueue(frame.data, keyframe: frame.keyframe, orientation: frame.orientation)
    }
}
