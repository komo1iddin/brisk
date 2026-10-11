import AppKit
import Synchronization
import Testing
import ZapFastBridge
@testable import FeatureConversation

@MainActor
struct TimelineCancellationTests {
    private func source(_ id: String) -> BubbleSource {
        BubbleSource(id: id, fromMe: false, startsRun: true, text: "Synthetic cancellation fixture",
                     emojiOnly: false, mentions: [], mentionNames: [:], senderName: nil, senderID: "sample",
                     forwarded: false, quote: nil, edited: false, timestamp: 1_780_000_000,
                     status: .none, reactions: [], colors: BubbleColors(.standard))
    }

    private func plan(_ source: BubbleSource) -> TimelineController.Plan {
        let message = MessageRecord(id: source.id, chat: "fixture", sender: "sample", senderName: nil, fromMe: false,
                                    timestamp: source.timestamp, content: .text(text: source.text, preview: nil), status: .none,
                                    deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
                                    mentions: [], forwarded: false, thumbnail: nil, summary: "")
        return .bubble(.message(message, startsRun: true, endsRun: true), source)
    }

    private actor DelayedMeasurement {
        private var release: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?
        private var didStart = false

        func waitUntilStarted() async {
            if didStart { return }
            await withCheckedContinuation { started = $0 }
        }
        func finish() { release?.resume(); release = nil }
        func measure(_ sources: [BubbleSource], limit: CGFloat) async -> [BubbleLayout] {
            await withCheckedContinuation { continuation in
                release = continuation
                didStart = true
                started?.resume()
                started = nil
            }
            // Deliberately ignores cancellation, as an already finishing
            // platform layout call may do. The controller must reject it.
            return TimelineLayoutEngine.layouts(for: sources, widthLimit: limit)
        }
    }

    @Test func anObsoleteFinishedBatchCannotOverwriteTheCurrentCache() async throws {
        let controller = TimelineController()
        _ = controller.makeScrollView()
        let delayed = DelayedMeasurement()
        controller.measureLayouts = { sources, limit, _, _ in await delayed.measure(sources, limit: limit) }
        controller.plans = (0..<12).map { plan(source("message-\($0)")) }
        controller.prepare(limit: 400)
        let old = try #require(controller.layoutTask)
        await delayed.waitUntilStarted()

        controller.plans = [plan(source("message-0"))]
        controller.prepare(limit: 200)
        #expect(controller.bubbleLayouts["message-0"]?.layout.widthLimit == 200)
        await delayed.finish()
        await old.value
        #expect(controller.bubbleLayouts.count == 1)
        #expect(controller.bubbleLayouts["message-0"]?.layout.widthLimit == 200)
        #expect(!controller.preparing)
    }

    @Test func cancelledParallelWorkStopsBeforeMeasuringEverySource() {
        let sources = (0..<300).map { source("message-\($0)") }
        let checks = Mutex(0)
        let layouts = TimelineLayoutEngine.layouts(for: sources, widthLimit: 400) {
            checks.withLock { value in value += 1; return value >= 5 }
        }
        #expect(layouts.isEmpty)
        #expect(checks.withLock { $0 } < sources.count)
    }

    @Test func cancelledQueuedWorkCannotReplaceTheLatestBatch() async {
        let scheduler = TimelineLayoutScheduler()
        let owner = UUID()
        let obsolete = TimelineLayoutCancellation()
        obsolete.cancel()
        #expect(await scheduler.measure([source("old")], limit: 400, owner: owner, cancellation: obsolete).isEmpty)
        let layouts = await scheduler.measure([source("new")], limit: 200, owner: owner,
                                              cancellation: TimelineLayoutCancellation())
        #expect(layouts.count == 1)
        #expect(layouts.first?.widthLimit == 200)
    }
}
