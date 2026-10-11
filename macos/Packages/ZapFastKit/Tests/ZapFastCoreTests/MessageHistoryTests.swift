import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct MessageHistoryTests {
    private func message(_ index: Int) -> MessageRecord {
        MessageRecord(id: "\(index)", chat: "fixture", sender: "sender", senderName: nil,
                      fromMe: false, timestamp: Int64(index), content: .text(text: "Fixture", preview: nil), status: .none,
                      deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
                      mentions: [], forwarded: false, thumbnail: nil, summary: "Fixture")
    }

    @Test(arguments: [0, 1, 255, 256, 257, 512, 10_000, 50_000])
    func retainedSnapshotsSurviveReceiptsAppendsAndDeletions(count: Int) {
        let original = (0..<count).map(message)
        var history = MessageHistory(original)
        let snapshot = history
        for index in [0, count / 2, count - 1] where index >= 0 && index < count {
            history[index].status = .read
        }
        history.append(message(count))
        #expect(Array(snapshot) == original)
        #expect(history.last?.id == "\(count)")
        let updated = history
        history.removeAll { Int($0.id)!.isMultiple(of: 3) }
        #expect(Array(history) == updated.filter { !Int($0.id)!.isMultiple(of: 3) })
        #expect(Array(snapshot) == original)
        #expect(updated.count == count + 1)
    }

    @Test func slicesKeepRunsAndCallOrderingAtNonzeroIndices() {
        let records = (0..<600).map(message)
        let history = MessageHistory(records)
        let slice = history[255..<513]
        #expect(Array(slice) == Array(records[255..<513]))
        #expect(TimelineRow.build(slice) == TimelineRow.build(Array(slice)))
        let call = CallLogEntry(callId: "fixture-call", chat: "fixture", fromMe: false, video: false,
                                outcome: .missed, timestamp: 400, duration: 0)
        #expect(TimelineRow.build(slice, calls: [call]) == TimelineRow.build(Array(slice), calls: [call]))
    }

    @Test func largeConversationSnapshotsKeepTheirOwnRevisionAndOrder() {
        let store = ConversationStore()
        store.protect(["fixture"])
        store.applyMessages(chat: "fixture", messages: (0..<50_000).map(message), older: false, complete: false)
        let snapshot = store.conversation("fixture")
        var receipt = message(25_000)
        receipt.status = .read
        store.applyUpdated(receipt)
        store.applyMessages(chat: "fixture", messages: [message(50_000)], older: false, complete: false)
        let latest = store.conversation("fixture")
        #expect(snapshot.messages.count == 50_000)
        #expect(snapshot.message("25000")?.status == .some(.none))
        #expect(latest.message("25000")?.status == .read)
        #expect(latest.messages.last?.id == "50000")
        #expect(latest.changes.suffix(2).first?.updated == [25_000])
        #expect(latest.messagesRevision == snapshot.messagesRevision + 2)
    }
}
