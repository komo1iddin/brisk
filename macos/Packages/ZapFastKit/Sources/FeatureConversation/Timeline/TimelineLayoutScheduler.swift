import Foundation
import Synchronization

nonisolated final class TimelineLayoutCancellation: Sendable {
    private let stopped = Atomic(false)
    var isCancelled: Bool { stopped.load(ordering: .relaxed) }
    func cancel() { stopped.store(true, ordering: .relaxed) }
}

/// One active parallel batch across timelines, one latest pending batch per
/// timeline. Replacing queued work releases its source snapshot immediately.
nonisolated final class TimelineLayoutScheduler: Sendable {
    static let shared = TimelineLayoutScheduler()

    private struct Job: Sendable {
        let sources: [BubbleSource]
        let limit: CGFloat
        let cancellation: TimelineLayoutCancellation
        let answer: CheckedContinuation<[BubbleLayout], Never>
    }
    private struct State {
        var pending: [UUID: Job] = [:]
        var order: [UUID] = []
        var running = false
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "zapfast.timeline-measure", qos: .userInitiated)

    func measure(_ sources: [BubbleSource], limit: CGFloat, owner: UUID,
                 cancellation: TimelineLayoutCancellation) async -> [BubbleLayout] {
        guard !cancellation.isCancelled else { return [] }
        return await withCheckedContinuation { answer in
            let job = Job(sources: sources, limit: limit, cancellation: cancellation, answer: answer)
            let (previous, start) = state.withLock { state -> (Job?, Bool) in
                guard !cancellation.isCancelled else { answer.resume(returning: []); return (nil, false) }
                let previous = state.pending.updateValue(job, forKey: owner)
                if previous == nil { state.order.append(owner) }
                let start = !state.running
                state.running = true
                return (previous, start)
            }
            previous?.cancellation.cancel()
            previous?.answer.resume(returning: [])
            if start { queue.async { self.drain() } }
        }
    }

    private func drain() {
        while let job = state.withLock({ state -> Job? in
            guard !state.order.isEmpty else { state.running = false; return nil }
            return state.pending.removeValue(forKey: state.order.removeFirst())
        }) {
            let layouts = TimelineLayoutEngine.layouts(for: job.sources, widthLimit: job.limit,
                                                       cancelled: { job.cancellation.isCancelled })
            job.answer.resume(returning: layouts)
        }
    }
}
