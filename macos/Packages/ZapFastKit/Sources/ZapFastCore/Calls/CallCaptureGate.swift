import Synchronization
import Foundation

/// Encoder/tap callbacks can outlive stop. A stopped capture cannot feed a
/// later call through the account's current-call bridge handle.
nonisolated final class CallCaptureGate: Sendable {
    private let active = Atomic<Bool>(true)
    private let delivery = NSLock()
    var isOpen: Bool { active.load(ordering: .acquiring) }
    func close() { delivery.withLock { active.store(false, ordering: .releasing) } }
    func forward(_ action: () -> Void) {
        delivery.withLock {
            guard isOpen else { return }
            action()
        }
    }
}
