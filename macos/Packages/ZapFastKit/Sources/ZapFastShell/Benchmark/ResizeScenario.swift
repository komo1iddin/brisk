import Foundation

/// Repeat the same short drag, restoring its width between rounds, so a
/// larger sample does not accidentally benchmark a much narrower window.
nonisolated struct ResizeScenario {
    let rounds: Int
    static let steps = 10
    static let pointsPerStep = 8

    init(requestedRounds: String?) {
        rounds = min(10, max(1, requestedRounds.flatMap(Int.init) ?? 1))
    }
}
