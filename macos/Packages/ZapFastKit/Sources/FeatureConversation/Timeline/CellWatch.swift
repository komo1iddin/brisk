import Foundation
import Observation

/// Something a drawn cell shows that changes on its own: a download's
/// state, a video playing in place. `read` runs under observation now and
/// again after each change to what it read, and `apply` hears each new
/// value, until the cell shows another message and stops it.
///
/// Only the cell's own message is read, so a change to another message
/// wakes no other cell (rule 1 in PERFORMANCE.md).
@MainActor
final class CellWatch<Value: Equatable> {
    private let read: () -> Value
    private let apply: (Value) -> Void
    private var last: Value?
    private var stopped = false

    init(read: @escaping () -> Value, apply: @escaping (Value) -> Void) {
        self.read = read
        self.apply = apply
        arm()
    }

    func stop() {
        stopped = true
    }

    private func arm() {
        guard !stopped else { return }
        let value = withObservationTracking(read) { [weak self] in
            // Heard before the change lands; read it on the next turn.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.arm() }
            }
        }
        guard value != last else { return }
        last = value
        apply(value)
    }
}

/// Watches of different values, stopped together.
@MainActor
struct CellWatches {
    private var stops: [() -> Void] = []

    mutating func watch<Value: Equatable>(_ read: @escaping () -> Value, apply: @escaping (Value) -> Void) {
        let watch = CellWatch(read: read, apply: apply)
        stops.append { watch.stop() }
    }

    mutating func stopAll() {
        stops.forEach { $0() }
        stops = []
    }
}
