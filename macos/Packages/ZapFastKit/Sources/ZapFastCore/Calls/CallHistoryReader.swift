import Foundation
import Synchronization
import ZapFastBridge

/// Blocking SQLite FFI belongs on one queue per account, without parking
/// the UI or many cooperative-executor threads behind its database mutex.
nonisolated final class CallHistoryReader: Sendable {
    private let queue = DispatchQueue(label: "ZapFast.CallHistory")
    private let center: CallCenter
    init(_ center: CallCenter) { self.center = center }

    func read(_ chat: String) async -> [CallLogEntry] {
        let request = ReadCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [center] in
                    guard !request.cancelled.load(ordering: .acquiring) else { continuation.resume(returning: []); return }
                    continuation.resume(returning: center.history(chat: chat))
                }
            }
        } onCancel: { request.cancelled.store(true, ordering: .releasing) }
    }
}

nonisolated private final class ReadCancellation: Sendable { let cancelled = Atomic<Bool>(false) }
