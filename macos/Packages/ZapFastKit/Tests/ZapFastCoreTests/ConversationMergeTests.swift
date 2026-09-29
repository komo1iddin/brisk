import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct ConversationMergeTests {
    private func message(_ id: String, at time: Int64, path: String? = nil) -> MessageRecord {
        MessageRecord(
            id: id, chat: "c@s.whatsapp.net", sender: "a@s.whatsapp.net", senderName: nil,
            fromMe: false, timestamp: time,
            content: .image(caption: nil, media: MediaInfo(mime: "image/jpeg", size: 1, width: nil, height: nil, path: path)),
            status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: nil, summary: "Photo"
        )
    }

    @Test func olderPagesPrependOnlyUnseenMessages() {
        var conversation = Conversation()
        conversation.merge([message("b", at: 2), message("c", at: 3)], older: false)
        conversation.merge([message("a", at: 1), message("b", at: 2)], older: true)
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

    @Test func timelineInsertsOneSeparatorPerDay() {
        let day: Int64 = 86_400
        let rows = TimelineRow.build([message("a", at: day), message("b", at: day + 60), message("c", at: day * 3)])
        let separators = rows.filter { if case .day = $0 { true } else { false } }
        #expect(separators.count == 2)
    }
}
