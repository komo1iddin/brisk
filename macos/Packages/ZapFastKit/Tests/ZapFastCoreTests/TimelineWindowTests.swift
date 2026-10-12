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

    @Test func oldPaneActionsResolveLiveRecordsOutsideTheNewestCache() throws {
        let (model, backend) = model()
        model.apply(.chats(chats: [ChatSummary(
            id: "fixture", name: "Synthetic chat", groupSubjectKnown: true, kind: .direct,
            lastActivity: 1, unread: 0, markedUnread: false, archived: false, pinned: false, pinnedAt: 0,
            mutedUntil: nil, last: nil, favorite: false, favoritePosition: 0, participants: [],
            readOnly: false, left: false, infoLocked: nil, admin: false, locked: false,
            ephemeralExpiration: nil, labels: [], hasCustomSound: false, isChannel: false,
            looksUnread: false, phone: nil)]))
        model.apply(.link(state: .connected))
        model.apply(.messages(chat: "fixture", messages: rows(100..<160), older: false, complete: false))
        let reader = model.openTimelineReader("fixture")
        var old = rows(0..<40)
        old[10].fromMe = true
        old[10].status = .delivered
        old[11].content = .poll(question: "Synthetic poll", options: ["A", "B"], state: PollSummary(
            selectable: 1, counts: [0, 0], selected: [], voters: 0, canVote: true,
            historyComplete: true, refreshNeeded: false, refreshing: false, refreshFailed: false, votes: []))
        old[12].content = .interactive(text: "Synthetic list", card: InteractiveCardInfo(
            body: "Choose", buttons: [InteractiveButtonInfo(label: "Options", url: nil, action: .select(options: [
                InteractiveOptionInfo(section: "Fixture", title: "A", description: "")
            ]))], image: nil, needsPhone: false, carousel: [], thumbnail: nil))
        model.readWindow(.around(message: "m10"), in: reader)
        try answer(model, reader, messages: old)
        #expect(model.conversations.conversation("fixture").message("m10") == nil)
        let info = try #require(model.loadedMessage(chat: "fixture", id: "m10"))
        model.showInfo(info)
        #expect(model.messageInfo == MessageKey(chat: "fixture", message: "m10"))
        model.showChoices(try #require(model.loadedMessage(chat: "fixture", id: "m12")), button: 0)
        #expect(model.interactiveList?.key.message == "m12")
        if case .poll? = model.loadedMessage(chat: "fixture", id: "m11")?.content {} else { Issue.record("Old poll missing") }
        var read = info
        read.status = .read
        read.readAt = 200
        model.apply(.messageUpdated(message: read))
        #expect(model.loadedMessage(chat: "fixture", id: "m10")?.readAt == 200)
        model.reloadHistory(before: read)
        #expect(reader.conversation.fetchingPhone)
        #expect(backend.sent.last == .reloadHistory(chat: "fixture", message: "m10"))
        model.apply(.messageDeleted(chat: "fixture", id: "m11"))
        #expect(model.loadedMessage(chat: "fixture", id: "m11") == nil)
        model.closeTimelineReader(reader)
        #expect(model.loadedMessage(chat: "fixture", id: "m10") == nil)
    }

    @Test func mediaPagesBothWaysWithoutMovingTheOldPaneAndReleasesItsReader() throws {
        let (model, _) = model()
        model.apply(.messages(chat: "fixture", messages: rows(200..<260), older: false, complete: false))
        let pane = model.openTimelineReader("fixture")
        var old = rows(100..<160)
        old[10].content = .image(caption: "Synthetic photo", media: MediaInfo(
            mime: "image/jpeg", size: 1, width: 10, height: 10, path: nil))
        model.readWindow(.around(message: "m110"), in: pane)
        try answer(model, pane, messages: old)
        model.openMediaViewer(old[10])
        let viewer = try #require(model.mediaViewerReader)
        #expect(viewer !== pane && viewer.conversation.message("m110") != nil)
        model.loadOlderMedia(in: "fixture")
        #expect(viewer.pending?.1 == .before(message: "m100"))
        try answer(model, viewer, messages: rows(40..<100))
        #expect(pane.conversation.messages.first?.id == "m100")
        model.loadNewerMedia(in: "fixture")
        #expect(viewer.pending?.1 == .after(message: "m159"))
        try answer(model, viewer, messages: rows(160..<220), newer: false)
        #expect(!model.mediaViewerConversation.hasNewer)
        model.closeMediaViewer()
        #expect(model.mediaViewerMessage == nil && model.mediaViewerReader == nil)
        #expect(model.timelineReaders.count == 1 && model.timelineReaders[pane.id] === pane)
    }

    @Test func theViewedPhotoSurvivesBoundedGalleryEvictionAndStillReceivesUpdates() throws {
        let (model, _) = model()
        var initial = rows(2_000..<2_060)
        initial[0].content = .image(caption: "Synthetic photo", media: MediaInfo(
            mime: "image/jpeg", size: 1, width: 10, height: 10, path: nil))
        model.apply(.messages(chat: "fixture", messages: initial, older: false, complete: false))
        model.openMediaViewer(initial[0])
        let viewer = try #require(model.mediaViewerReader)
        var upper = 2_000
        for _ in 0..<5 {
            model.loadOlderMedia(in: "fixture")
            try answer(model, viewer, messages: rows((upper - 300)..<upper))
            upper -= 300
            #expect(viewer.conversation.messages.count <= HistoryBudget.standard.rows)
            #expect(viewer.conversation.retainedBytes <= HistoryBudget.standard.bytes)
        }
        #expect(viewer.conversation.messages.first?.id == "m500")
        #expect(viewer.conversation.message("m2000") == nil)
        #expect(model.mediaViewerMessage?.id == "m2000")
        model.apply(.messages(chat: "fixture", messages: rows(2_060..<3_360), older: false, complete: false))
        #expect(model.conversations.conversation("fixture").message("m2000") == nil)
        model.apply(.media(chat: "fixture", message: "m2000", card: nil, path: "/tmp/synthetic.jpg", error: nil))
        var edited = initial[0]
        edited.edited = true
        model.apply(.messageUpdated(message: edited))
        #expect(model.mediaViewerMessage?.mediaURL?.path == "/tmp/synthetic.jpg")
        #expect(model.mediaViewerMessage?.edited == true)
        model.focusMedia()
        #expect(viewer.pending?.1 == .around(message: "m2000"))
        try answer(model, viewer, messages: initial)
        #expect(viewer.conversation.message("m2000") != nil)
        model.apply(.messageDeleted(chat: "fixture", id: "m2000"))
        #expect(model.mediaViewerMessage == nil)
        model.closeMediaViewer()
        #expect(model.timelineReaders.isEmpty)
    }
}
