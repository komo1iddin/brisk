import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct SearchTests {
    private let chat = "c@s.whatsapp.net"

    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-search-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        return (model, backend)
    }

    private func message(_ id: String, at time: Int64, in chat: String? = nil, text: String = "hello") -> MessageRecord {
        MessageRecord(
            id: id, chat: chat ?? self.chat, sender: "a@s.whatsapp.net", senderName: nil,
            fromMe: false, timestamp: time, content: .text(text: text, preview: nil),
            status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: nil, summary: text
        )
    }

    private func summary(_ id: String, locked: Bool) -> ChatSummary {
        ChatSummary(
            id: id, name: "Chat", groupSubjectKnown: true, kind: .direct, lastActivity: 1, unread: 0,
            markedUnread: false, archived: false, pinned: false, pinnedAt: 0, mutedUntil: nil, last: nil,
            favorite: false, favoritePosition: 0, participants: [], readOnly: false, left: false,
            infoLocked: nil, admin: false, locked: locked, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: false, looksUnread: false, phone: nil
        )
    }

    private func loadUntilCount(_ backend: PreviewBackend) -> Int {
        backend.sent.count { if case .loadUntil = $0 { true } else { false } }
    }

    // MARK: Jumping to a message

    @Test func jumpToALoadedMessageScrollsAndHighlightsAtOnce() {
        let (model, backend) = model()
        model.apply([.messages(chat: chat, messages: [message("a", at: 1), message("b", at: 2)], older: false, complete: true)])

        model.reveal(MessageKey(chat: chat, message: "a"))

        #expect(model.jump?.key == MessageKey(chat: chat, message: "a"))
        #expect(model.highlighted == MessageKey(chat: chat, message: "a"))
        #expect(loadUntilCount(backend) == 0)
    }

    @Test func jumpAboveTheLoadedPageAsksTheArchiveOnceThenScrolls() {
        let (model, backend) = model()
        model.selectedChatID = chat
        model.apply([.messages(chat: chat, messages: [message("m", at: 50)], older: false, complete: false)])

        model.reveal(MessageKey(chat: chat, message: "a"))
        #expect(model.jump == nil)
        #expect(backend.sent.last == .loadUntil(chat: chat, message: "a", before: PageKey(timestamp: 50, id: "m")))

        model.apply([.messages(chat: chat, messages: [message("a", at: 1), message("k", at: 20)], older: true, complete: false)])
        #expect(model.jump?.key.message == "a")
        #expect(loadUntilCount(backend) == 1)
    }

    @Test func jumpIntoAChatNotYetOpenWaitsForItsFirstPage() {
        let (model, backend) = model()

        model.reveal(MessageKey(chat: chat, message: "a"))
        #expect(model.selectedChatID == chat)
        #expect(backend.sent.contains(.loadChat(chat: chat, before: nil)))
        #expect(loadUntilCount(backend) == 0)

        model.apply([.messages(chat: chat, messages: [message("m", at: 50)], older: false, complete: false)])
        #expect(loadUntilCount(backend) == 1)
    }

    @Test func aMessageTheArchiveLacksEndsTheJumpWithoutAskingAgain() {
        let (model, backend) = model()
        model.selectedChatID = chat
        model.apply([.messages(chat: chat, messages: [message("m", at: 50)], older: false, complete: false)])
        model.reveal(MessageKey(chat: chat, message: "gone"))

        // Upstream answers an unknown message with an empty older page.
        model.apply([.messages(chat: chat, messages: [], older: true, complete: false)])
        model.apply([.messages(chat: chat, messages: [message("n", at: 60)], older: false, complete: false)])

        #expect(model.jump == nil)
        #expect(loadUntilCount(backend) == 1)
    }

    @Test func openingAnotherChatDropsAPendingJump() {
        let (model, backend) = model()
        model.selectedChatID = chat
        model.apply([.messages(chat: chat, messages: [message("m", at: 50)], older: false, complete: false)])
        model.reveal(MessageKey(chat: chat, message: "a"))

        model.selectedChatID = "other@s.whatsapp.net"
        model.apply([.messages(chat: chat, messages: [message("a", at: 1)], older: true, complete: false)])

        #expect(model.jump == nil)
        #expect(loadUntilCount(backend) == 1)
    }

    // MARK: Search answers

    @Test func messageHitsForAnEarlierQueryAreIgnored() {
        let (model, _) = model()
        model.searchMessages("hel")
        model.searchMessages("hello")

        model.apply([.searchHits(query: "hel", messages: [message("a", at: 1)])])
        #expect(model.search.messageHits.isEmpty)

        model.apply([.searchHits(query: "hello", messages: [message("b", at: 2)])])
        #expect(model.search.messageHits.map(\.id) == ["b"])
    }

    @Test func lockedChatsStayOutOfMessageHits() {
        let (model, _) = model()
        model.apply([.chats(chats: [summary(chat, locked: false), summary("secret@s.whatsapp.net", locked: true)])])
        model.searchMessages("hello")

        model.apply([.searchHits(query: "hello", messages: [
            message("a", at: 1),
            message("b", at: 2, in: "secret@s.whatsapp.net"),
        ])])

        #expect(model.search.messageHits.map(\.id) == ["a"])
    }

    @Test func chatHitsApplyOnlyToTheQueryInTheField() {
        let (model, _) = model()
        model.selectedChatID = chat
        model.openChatSearch()
        model.setChatSearchQuery("hel")
        model.setChatSearchQuery("hello ")
        #expect(model.search.chat?.pending == true)

        model.apply([.chatHits(chat: chat, query: "hel", from: nil, until: nil, messages: [message("a", at: 1)], truncated: false)])
        #expect(model.search.chat?.hits.isEmpty == true)

        model.apply([.chatHits(chat: chat, query: "hello", from: nil, until: nil, messages: [message("b", at: 2)], truncated: true)])
        #expect(model.search.chat?.hits.map(\.id) == ["b"])
        #expect(model.search.chat?.truncated == true)
        #expect(model.search.chat?.pending == false)
    }

    @Test func findNextWalksFromNewestToOldestAndStops() {
        let (model, _) = model()
        model.selectedChatID = chat
        model.apply([.messages(chat: chat, messages: [message("a", at: 1), message("b", at: 2)], older: false, complete: true)])
        model.openChatSearch()
        model.setChatSearchQuery("hello")
        model.apply([.chatHits(chat: chat, query: "hello", from: nil, until: nil,
                               messages: [message("b", at: 2), message("a", at: 1)], truncated: false)])

        model.stepChatSearch(older: true)
        #expect(model.jump?.key.message == "b")
        model.stepChatSearch(older: true)
        model.stepChatSearch(older: true)
        #expect(model.jump?.key.message == "a")
        model.stepChatSearch(older: false)
        #expect(model.search.chat?.selected == 0)
    }

    @Test func switchingChatsClosesTheChatSearch() {
        let (model, _) = model()
        model.selectedChatID = chat
        model.openChatSearch()
        model.selectedChatID = "other@s.whatsapp.net"
        #expect(model.search.chat == nil)
    }

    // MARK: Snippets

    @Test func snippetMarksEveryMatchIgnoringCaseAndAccents() {
        let snippet = SearchSnippet.make("Café or cafe, CAFE", matching: "cafe")
        let bold = snippet.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(bold.map { String(snippet[$0.range].characters) } == ["Café", "cafe", "CAFE"])
    }

    @Test func snippetCutsALongLeadSoTheMatchShows() {
        let text = String(repeating: "word ", count: 40) + "needle at the end"
        let snippet = String(SearchSnippet.make(text, matching: "needle").characters)
        #expect(snippet.hasPrefix("…"))
        #expect(snippet.contains("needle at the end"))
        #expect(snippet.count < 60)
    }
}
