import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct TimelineWindowTests {
    private func rows(_ range: Range<Int>, text: String = "Synthetic window fixture") -> [MessageRecord] {
        range.map { index in
            MessageRecord(id: "m\(index)", chat: "fixture", sender: "sender", senderName: nil,
                          fromMe: false, timestamp: Int64(index), content: .text(text: text, preview: nil),
                          status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
                          mentions: [], forwarded: false, thumbnail: nil, summary: "")
        }
    }
    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-window-\(UUID())")
        return (AppModel(backend: backend, paths: AppPaths(data: folder, caches: folder),
                         preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)), backend)
    }
    private func answer(_ model: AppModel, _ reader: TimelineReader, messages: [MessageRecord],
                        older: Bool = true, newer: Bool = true, error: String? = nil) throws {
        let pending = try #require(reader.pending)
        model.apply([.messageWindow(chat: reader.chat, request: pending.0, messages: messages,
                                    hasOlder: older, hasNewer: newer, error: error)])
    }

    @Test func fiftyThousandRowsRespectTheActiveBudget() {
        let store = ConversationStore()
        store.protect(["fixture"])
        store.applyMessages(chat: "fixture", messages: rows(0..<50_000), older: false, complete: true)
        let state = store.conversation("fixture")
        #expect(state.messages.count <= HistoryBudget.standard.rows)
        #expect(state.retainedBytes <= HistoryBudget.standard.bytes)
        #expect(state.messages.last?.id == "m49999")
        #expect(!state.complete && !state.hasNewer)
    }

    @Test func byteBudgetCountsThumbnailsAndNestedStrings() {
        let store = ConversationStore(inactiveChatLimit: 8, inactiveRowLimit: 100,
                                      historyBudget: HistoryBudget(rows: 100, bytes: 20_000))
        var messages = rows(0..<20, text: String(repeating: "q", count: 1_000))
        for index in messages.indices { messages[index].thumbnail = Data(repeating: 7, count: 4_000) }
        store.applyMessages(chat: "fixture", messages: messages, older: false, complete: true)
        let state = store.conversation("fixture")
        #expect(state.messages.count < 20)
        #expect(state.retainedBytes <= 20_000)
        #expect(state.messages.last?.id == "m19")
        #expect(!state.complete)
    }

    @Test func aSingleOversizedMessageRemainsReadable() {
        let store = ConversationStore(inactiveChatLimit: 1, inactiveRowLimit: 100,
                                      historyBudget: HistoryBudget(rows: 100, bytes: 1_000))
        store.applyMessages(chat: "fixture", messages: rows(0..<3, text: String(repeating: "x", count: 5_000)),
                            older: false, complete: true)
        let state = store.conversation("fixture")
        #expect(state.messages.count == 1 && state.messages.last?.id == "m2")
        #expect(state.oversizedMessage && state.retainedBytes > 1_000)
    }

    @Test func anAroundReadPrioritizesItsTargetUnderTheByteBudget() {
        let store = ConversationStore(inactiveChatLimit: 1, inactiveRowLimit: 100,
                                      historyBudget: HistoryBudget(rows: 100, bytes: 1_000))
        store.retentionAnchor = "retired-anchor"
        store.applyWindow(chat: "fixture", messages: rows(0..<9, text: String(repeating: "x", count: 5_000)),
                          query: .around(message: "m4"), hasOlder: false, hasNewer: false)
        #expect(store.conversation("fixture").messages.map(\.id) == ["m4"])
        #expect(store.conversation("fixture").oversizedMessage)
        #expect(!store.conversation("fixture").complete && store.conversation("fixture").hasNewer)
        store.applyWindow(chat: "fixture", messages: rows(100..<105), query: .newest, hasOlder: true, hasNewer: false)
        #expect(store.conversation("fixture").messages.last?.id == "m104")
    }

    @Test func pagingBackThenForwardRestoresEvictedEdges() {
        let store = ConversationStore(inactiveChatLimit: 1, inactiveRowLimit: 100,
                                      historyBudget: HistoryBudget(rows: 8, bytes: 1_000_000))
        store.applyWindow(chat: "fixture", messages: rows(20..<26), query: .newest, hasOlder: true, hasNewer: false)
        store.applyWindow(chat: "fixture", messages: rows(14..<20), query: .before(message: "m20"), hasOlder: true, hasNewer: true)
        #expect(store.conversation("fixture").messages.map(\.id) == rows(14..<20).map(\.id))
        #expect(store.conversation("fixture").hasNewer)
        store.applyWindow(chat: "fixture", messages: rows(20..<26), query: .after(message: "m19"), hasOlder: true, hasNewer: false)
        #expect(store.conversation("fixture").messages.map(\.id) == rows(20..<26).map(\.id))
        #expect(!store.conversation("fixture").hasNewer)
    }

    @Test func liveArrivalsKeepAnAwayReadersVisibleAnchor() {
        let store = ConversationStore(inactiveChatLimit: 1, inactiveRowLimit: 100,
                                      historyBudget: HistoryBudget(rows: 8, bytes: 1_000_000))
        store.applyMessages(chat: "fixture", messages: rows(0..<8), older: false, complete: true)
        store.retentionAnchor = "m2"
        store.applyMessages(chat: "fixture", messages: rows(8..<9), older: false, complete: false)
        #expect(store.conversation("fixture").message("m2") != nil)
        #expect(store.conversation("fixture").hasNewer)
        #expect(store.conversation("fixture").messages.count <= 8)
    }

    @Test func twoPanesPageIndependentlyAndLiveEventsDoNotCreateGaps() throws {
        let (model, _) = model()
        model.apply(.messages(chat: "fixture", messages: rows(100..<160), older: false, complete: false))
        let first = model.openTimelineReader("fixture")
        let second = model.openTimelineReader("fixture")
        model.readWindow(.around(message: "m20"), in: first)
        try answer(model, first, messages: rows(0..<40), older: false)
        #expect(first.conversation.message("m20") != nil)
        #expect(second.conversation.messages.first?.id == "m100")
        model.apply(.messages(chat: "fixture", messages: rows(160..<161), older: false, complete: false))
        #expect(first.conversation.message("m160") == nil)
        #expect(second.conversation.message("m160") != nil)
        #expect(model.loadedMessage(chat: "fixture", id: "m20") != nil)
        model.loadNewer(in: first)
        try answer(model, first, messages: rows(40..<100))
        #expect(first.conversation.messages.last?.id == "m99")
        #expect(second.conversation.messages.first?.id == "m100")
    }

    @Test func staleRepliesAndClearCannotRestoreOldRows() throws {
        let (model, _) = model()
        model.apply(.messages(chat: "fixture", messages: rows(100..<160), older: false, complete: false))
        let reader = model.openTimelineReader("fixture")
        model.readWindow(.around(message: "m20"), in: reader)
        let stale = try #require(reader.pending?.0)
        model.readWindow(.newest, in: reader)
        model.apply(.messageWindow(chat: "fixture", request: stale, messages: rows(0..<40), hasOlder: false, hasNewer: true, error: nil))
        #expect(reader.conversation.messages.first?.id == "m100")
        let latest = try #require(reader.pending?.0)
        model.apply(.chatCleared(chat: "fixture", through: .max))
        model.apply(.messageWindow(chat: "fixture", request: latest, messages: rows(100..<160), hasOlder: true, hasNewer: false, error: nil))
        #expect(reader.conversation.messages.isEmpty)
        #expect(reader.pending == nil)
    }

    @Test func failedReadsClearLoadingAndRetainTheCurrentWindow() throws {
        let (model, _) = model()
        model.apply(.messages(chat: "fixture", messages: rows(100..<160), older: false, complete: false))
        let reader = model.openTimelineReader("fixture")
        model.loadOlder(in: reader)
        try answer(model, reader, messages: [], error: "Could not read the chat archive")
        #expect(!reader.conversation.loadingOlder && reader.pending == nil)
        #expect(reader.conversation.messages.count == 60)
        let noticeCount = model.notices.count
        let stale = UUID().uuidString
        model.apply(.messageWindow(chat: "fixture", request: stale, messages: [], hasOlder: false, hasNewer: false, error: "stale"))
        #expect(model.notices.count == noticeCount)
        model.closeTimelineReader(reader)
        #expect(model.timelineReaders.isEmpty)
    }

    @Test func ordinaryBeforeAndAfterPagesPreserveTheOppositeEdge() {
        let store = ConversationStore()
        store.applyWindow(chat: "fixture", messages: rows(60..<120), query: .newest, hasOlder: true, hasNewer: false)
        store.applyWindow(chat: "fixture", messages: rows(0..<60), query: .before(message: "m60"), hasOlder: false, hasNewer: true)
        #expect(store.conversation("fixture").complete && !store.conversation("fixture").hasNewer)
        store.applyWindow(chat: "fixture", messages: rows(120..<130), query: .after(message: "m119"), hasOlder: true, hasNewer: false)
        #expect(store.conversation("fixture").complete)
    }
}
