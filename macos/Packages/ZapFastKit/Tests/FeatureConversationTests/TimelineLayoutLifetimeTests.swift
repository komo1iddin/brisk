import AppKit
import Testing
import ZapFastBridge
import ZapFastCore
@testable import FeatureConversation

@MainActor
struct TimelineLayoutLifetimeTests {
    private final class Witness {
        weak var layout: BubbleLayout?

        init(_ layout: BubbleLayout) { self.layout = layout }
    }

    private func releasedBatch(count: Int) -> [Witness] {
        let sources = (0..<count).map { index in
            BubbleSource(
                id: "lifetime-\(index)", fromMe: false, startsRun: true,
                text: "Synthetic lifetime message", emojiOnly: false, mentions: [],
                mentionNames: [:], senderName: "Sample", senderID: "sample",
                forwarded: false, quote: nil, edited: false, timestamp: 1_780_000_000,
                status: .none, reactions: [], colors: BubbleColors(TimelineStyle.standard)
            )
        }
        return TimelineLayoutEngine.layouts(for: sources, widthLimit: 420).map(Witness.init)
    }

    @Test(arguments: [0, 1, 32, 33, 64, 65, 129])
    func aFinishedBatchReleasesEveryLayout(count: Int) {
        let witnesses = releasedBatch(count: count)
        #expect(witnesses.count == count)
        #expect(witnesses.allSatisfy { $0.layout == nil })
    }

    @Test func repeatedParallelBatchesReleaseTheirLayouts() {
        var witnesses: [Witness] = []
        for _ in 0..<20 { witnesses += releasedBatch(count: 129) }
        #expect(witnesses.allSatisfy { $0.layout == nil })
    }
}
