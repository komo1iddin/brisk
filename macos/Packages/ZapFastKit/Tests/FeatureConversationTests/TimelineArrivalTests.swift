import Testing
import ZapFastBridge
@testable import FeatureConversation

@MainActor
struct TimelineArrivalTests {
    private func item(_ id: String, at timestamp: Int64, fromMe: Bool = false) -> TimelineController.Item {
        let message = MessageRecord(id: id, chat: "fixture", sender: "sample", senderName: nil, fromMe: fromMe,
                                    timestamp: timestamp, content: .text(text: "Synthetic history badge fixture", preview: nil), status: .none,
                                    deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
                                    mentions: [], forwarded: false, thumbnail: nil, summary: "")
        return .hosted(.message(message, startsRun: true, endsRun: true), height: 40)
    }

    @Test func historyPrependAndBackfillDoNotCountAsArrivals() {
        let old = [item("first", at: 100), item("tail", at: 200)]
        let history = [item("older", at: 50), old[0], item("gap", at: 150), old[1]]
        #expect(TimelineArrivals.count(from: old, to: history) == 0)
        #expect(TimelineArrivals.count(from: [], to: history) == 0)
    }

    @Test func liveIncomingAfterTheTailCountsEvenInTheSameSecond() {
        let old = [item("tail", at: 200)]
        let new = [item("history", at: 100), old[0], item("live", at: 200), item("own", at: 201, fromMe: true)]
        #expect(TimelineArrivals.count(from: old, to: new) == 1)
        #expect(TimelineArrivals.count(from: new, to: new) == 0)
    }

    @Test func removalOfTheOldTailDoesNotCountOlderRows() {
        let old = [item("tail", at: 200)]
        let new = [item("history", at: 100), item("live", at: 201)]
        #expect(TimelineArrivals.count(from: old, to: new) == 1)
    }
}
