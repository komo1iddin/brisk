import AppKit
import Testing
import ZapFastBridge
import ZapFastCore
@testable import FeatureConversation

/// Temporary audit regression probe. Uses synthetic text only.
@MainActor
struct AuditLayoutLifetimeTests {
    final class Witness {
        weak var layout: BubbleLayout?
    }

    private func releasedBatch(count: Int) -> Witness {
        let sources = (0..<count).map { index in
            BubbleSource(
                id: "audit-\(index)", fromMe: false, startsRun: true,
                text: "Synthetic audit message", emojiOnly: false, mentions: [],
                mentionNames: [:], senderName: "Sample", senderID: "sample",
                forwarded: false, quote: nil, edited: false, timestamp: 1_780_000_000,
                status: .none, reactions: [], colors: BubbleColors(TimelineStyle.standard)
            )
        }
        let witness = Witness()
        let layouts = TimelineLayoutEngine.layouts(for: sources, widthLimit: 420)
        witness.layout = layouts.first
        return witness
    }

    @Test func serialBatchReleasesItsLayouts() {
        #expect(releasedBatch(count: 8).layout == nil)
    }

    @Test func parallelBatchReleasesItsLayouts() {
        #expect(releasedBatch(count: 64).layout == nil)
    }
}
