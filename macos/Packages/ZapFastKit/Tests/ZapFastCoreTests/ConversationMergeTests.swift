import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct ConversationMergeTests {
    private func message(_ id: String, at time: Int64, path: String? = nil, order: Int64? = nil) -> MessageRecord {
        MessageRecord(
            id: id, chat: "c@s.whatsapp.net", sender: "a@s.whatsapp.net", senderName: nil,
            fromMe: false, timestamp: time,
            content: .image(caption: nil, media: MediaInfo(mime: "image/jpeg", size: 1, width: nil, height: nil, path: path)),
            status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: nil, summary: "Photo", historyOrder: order
        )
    }

    @Test func olderPagesPrependOnlyUnseenMessages() {
        var conversation = Conversation()
        conversation.merge([message("b", at: 2), message("c", at: 3)], older: false)
        conversation.merge([message("a", at: 1), message("b", at: 2)], older: true)
        #expect(conversation.messages.map(\.id) == ["a", "b", "c"])
    }

    @Test func theSameSecondFollowsThePhonesHistoryOrder() {
        var conversation = Conversation()
        conversation.merge([message("live", at: 5), message("second", at: 5, order: 2)], older: false)
        conversation.merge([message("first", at: 5, order: 1)], older: false)
        #expect(conversation.messages.map(\.id) == ["first", "second", "live"])
    }

    @Test func messagesWithoutHistoryOrderKeepTheirArrivalOrder() {
        var conversation = Conversation()
        conversation.merge([message("b", at: 5), message("c", at: 5), message("a", at: 4)], older: false)
        #expect(conversation.messages.map(\.id) == ["a", "b", "c"])
    }

    @Test func freshCopyKeepsADownloadedFile() {
        var conversation = Conversation()
        conversation.merge([message("a", at: 1, path: "/tmp/a.jpg")], older: false)
        conversation.merge([message("a", at: 1)], older: false)
        #expect(conversation.messages.first?.mediaURL?.path == "/tmp/a.jpg")
    }

    @Test func firstPageDecidesCompleteness() {
        let store = ConversationStore()
        let bare = store.applyMessages(chat: "c", messages: [], older: false, complete: true)
        #expect(bare)
        #expect(store.conversation("c").complete)
    }

    @Test func aPhoneAnswerPagesTheArchiveAgain() {
        let store = ConversationStore()
        _ = store.applyMessages(chat: "c", messages: [message("a", at: 5)], older: false, complete: true)
        #expect(store.conversation("c").complete)
        // An answer that came after the request timed out is in the archive.
        store.applyOlderFetched(chat: "c", more: true)
        #expect(!store.conversation("c").complete)
        #expect(store.conversation("c").oldestKey?.id == "a")
    }

    @Test func timelineInsertsOneSeparatorPerDay() {
        let day: Int64 = 86_400
        let rows = TimelineRow.build([message("a", at: day), message("b", at: day + 60), message("c", at: day * 3)])
        let separators = rows.filter { if case .day = $0 { true } else { false } }
        #expect(separators.count == 2)
    }

    @Test func aChangedTimestampResortsAndClearsTheIncrementalJournal() {
        let store = ConversationStore()
        store.protect(["c"])
        store.applyMessages(chat: "c", messages: [message("a", at: 1), message("b", at: 2), message("c", at: 3)], older: false, complete: false)
        var changed = message("a", at: 4)
        changed.chat = "c"
        store.applyUpdated(changed)
        #expect(store.conversation("c").messages.map(\.id) == ["b", "c", "a"])
        #expect(store.conversation("c").changes.isEmpty)
    }

    @Test func theJournalContainsCoalescedReceiptsAndAppendsButNotHistoryOrDeletion() {
        let store = ConversationStore()
        store.protect(["c"])
        store.applyMessages(chat: "c", messages: [message("a", at: 1)], older: false, complete: false)
        var receipt = message("a", at: 1)
        receipt.chat = "c"
        receipt.status = .read
        store.applyUpdated(receipt)
        store.applyMessages(chat: "c", messages: [message("b", at: 2)], older: false, complete: false)
        let changes = store.conversation("c").changes
        #expect(changes.count == 3)
        #expect(changes[1].updated == [0])
        #expect(changes[2].previousCount == 1 && changes[2].count == 2)
        store.applyMessages(chat: "c", messages: [message("older", at: 0)], older: true, complete: true)
        #expect(store.conversation("c").changes.isEmpty)
        store.applyDeleted(chat: "c", id: "a")
        #expect(store.conversation("c").changes.isEmpty)
    }

    @Test func revisionHistoryIsBoundedAndPagingFlagsDoNotEraseIt() {
        let store = ConversationStore()
        store.protect(["c"])
        for index in 0..<80 {
            store.applyMessages(chat: "c", messages: [message("\(index)", at: Int64(index))], older: false, complete: false)
        }
        let before = store.conversation("c")
        #expect(before.changes.count == 32)
        store.markLoadingOlder("c")
        let after = store.conversation("c")
        #expect(after.messagesRevision == before.messagesRevision)
        #expect(after.changes == before.changes)
    }
}
