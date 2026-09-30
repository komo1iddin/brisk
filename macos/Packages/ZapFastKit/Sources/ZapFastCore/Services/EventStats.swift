import Foundation
import OSLog
import ZapFastBridge

/// How many backend events of each kind arrived, and the main-thread time
/// applying them took, logged every ten seconds when anything arrived
/// (subsystem ZapFast, category Events). Only the kinds' names and numbers
/// are logged, never what an event carries. A storm of events, such as the
/// whole chat list sent again and again, shows here.
@MainActor
final class EventStats {
    private let log = Logger(subsystem: "ZapFast", category: "Events")
    private var counts: [String: Int] = [:]
    private var cost: [String: Double] = [:]
    private var windowStart = Date()

    func measure(_ event: BridgeEvent, _ apply: () -> Void) {
        let start = Self.threadMilliseconds()
        apply()
        let spent = Self.threadMilliseconds() - start
        let kind = Mirror(reflecting: event).children.first?.label ?? "\(event)".prefix { $0 != "(" }.description
        counts[kind, default: 0] += 1
        cost[kind, default: 0] += spent
        let now = Date()
        guard now.timeIntervalSince(windowStart) >= 10 else { return }
        let total = cost.values.reduce(0, +)
        let summary = counts.sorted { cost[$0.key, default: 0] > cost[$1.key, default: 0] }
            .map { "\($0.key)×\($0.value) \(Int(cost[$0.key, default: 0]))ms" }
            .joined(separator: ", ")
        log.notice("Events: \(Int(now.timeIntervalSince(self.windowStart)), privacy: .public) s, \(Int(total), privacy: .public) ms applying: \(summary, privacy: .public)")
        counts = [:]
        cost = [:]
        windowStart = now
    }

    private static func threadMilliseconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
    }
}
