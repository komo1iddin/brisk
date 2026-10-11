import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct ConversationRetentionTests {
    private func rows(_ chat: String, count: Int) -> [MessageRecord] {
        (0..<count).map { index in
            MessageRecord(id: "\(index)", chat: chat, sender: "sample", senderName: nil, fromMe: false,
                          timestamp: Int64(index), content: .text(text: "Synthetic retention fixture", preview: nil),
                          status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
                          mentions: [], forwarded: false, thumbnail: nil, summary: "")
        }
    }

    @Test func fiftyPagedChatsRetainOnlyTheInactiveBudget() {
        let store = ConversationStore()
        store.protect(["open"])
        store.applyMessages(chat: "open", messages: rows("open", count: 15_000), older: false, complete: true)
        for index in 0..<50 {
            let chat = "inactive-\(index)"
            store.applyMessages(chat: chat, messages: rows(chat, count: 3_000), older: false, complete: true)
        }
        #expect(store.conversation("open").messages.count == 15_000)
        let inactive = (0..<50).map { store.conversation("inactive-\($0)") }
        #expect(inactive.reduce(0) { $0 + $1.messages.count } <= 12_000)
        #expect(inactive.count { !$0.messages.isEmpty } <= 8)
        #expect(!store.conversation("inactive-0").requested)
        #expect(store.conversation("inactive-49").requested)
    }

    @Test func pressurePreservesOpenWindowsAndRunningHistoryRequests() {
        let store = ConversationStore()
        store.protect(["pane", "window"])
        for chat in ["pane", "window", "fetching", "paging", "inactive"] {
            store.applyMessages(chat: chat, messages: rows(chat, count: 10), older: false, complete: false)
        }
        store.markFetchingPhone("fetching")
        store.markLoadingOlder("paging")
        store.trimInactive(all: true)
        #expect(store.conversation("pane").messages.count == 10)
        #expect(store.conversation("window").messages.count == 10)
        #expect(store.conversation("fetching").fetchingPhone)
        #expect(store.conversation("paging").loadingOlder)
        #expect(store.conversation("inactive").messages.isEmpty)
        #expect(!store.conversation("inactive").requested)
    }

    @Test func anEvictedChatCanReloadAndPageFromTheArchive() {
        let store = ConversationStore(inactiveChatLimit: 1, inactiveRowLimit: 20)
        store.applyMessages(chat: "old", messages: rows("old", count: 5), older: false, complete: true)
        store.applyMessages(chat: "new", messages: rows("new", count: 5), older: false, complete: false)
        let evicted = store.conversation("old")
        #expect(evicted.messages.isEmpty && !evicted.requested && !evicted.complete)
        store.protect(["old"])
        store.markRequested("old")
        store.applyMessages(chat: "old", messages: rows("old", count: 5), older: false, complete: false)
        #expect(store.conversation("old").messages.count == 5)
        #expect(store.conversation("old").oldestKey?.id == "0")
        #expect(!store.conversation("old").complete)
        #expect(store.conversation("old").messagesRevision > evicted.messagesRevision)
    }
}
