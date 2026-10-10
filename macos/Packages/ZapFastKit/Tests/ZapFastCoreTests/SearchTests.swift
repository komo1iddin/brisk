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

    @Test func clickingAQuoteJumpsToTheQuotedMessage() {
        let (model, backend) = model()
        model.selectedChatID = chat
        var reply = message("r", at: 60)
        reply.quoted = QuotedMessage(id: "a", sender: "a@s.whatsapp.net", senderName: nil, summary: "hello", mentions: [])
        model.apply([.messages(chat: chat, messages: [message("m", at: 50), reply], older: false, complete: false)])

        model.showQuoted(in: reply)
        #expect(backend.sent.last == .loadUntil(chat: chat, message: "a", before: PageKey(timestamp: 50, id: "m")))

        model.apply([.messages(chat: chat, messages: [message("a", at: 1)], older: true, complete: false)])
        #expect(model.jump?.key == MessageKey(chat: chat, message: "a"))
        #expect(model.highlighted == MessageKey(chat: chat, message: "a"))
    }

    @Test func aQuoteWithoutAnIDGoesNowhere() {
        let (model, backend) = model()
        var reply = message("r", at: 60)
        reply.quoted = QuotedMessage(id: "", sender: "a@s.whatsapp.net", senderName: nil, summary: "hello", mentions: [])

        model.showQuoted(in: reply)
        #expect(model.selectedChatID == nil)
        #expect(backend.sent.isEmpty)
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

    /// The last search sent, as the backend received it.
    private func lastSearch(_ backend: PreviewBackend) -> (request: UInt64, query: String, from: Int64?, until: Int64?, sender: SearchSenderInfo?, kind: SearchKindInfo?)? {
        for command in backend.sent.reversed() {
            if case let .searchChat(_, request, query, from, until, sender, kind, _) = command {
                return (request, query, from, until, sender, kind)
            }
        }
        return nil
    }

    /// The search sent once typing paused, waiting for it as long as a busy
    /// test run may need.
    private func sentSearch(_ backend: PreviewBackend, after count: Int = 0) async throws -> UInt64 {
        for _ in 0..<100 {
            let sent = backend.sent.filter { if case .searchChat = $0 { true } else { false } }
            if sent.count > count, let last = lastSearch(backend) { return last.request }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("no search was sent")
        return 0
    }

    private func answer(_ model: AppModel, _ request: UInt64, ids: [String], truncated: Bool = false) {
        model.apply([.chatSearchHits(
            chat: chat, request: request, ids: ids,
            messages: ids.enumerated().map { message($1, at: Int64(100 - $0)) }, truncated: truncated
        )])
    }

    @Test func onlyTheAnswerToTheLastSearchIsShown() async throws {
        let (model, backend) = model()
        model.selectedChatID = chat
        model.openChatSearch()
        model.setChatSearchQuery("hel")
        let first = model.search.chat?.request ?? 0
        model.setChatSearchQuery("hello ")
        #expect(model.search.chat?.pending == true)
        _ = try await sentSearch(backend)
        let sent = try #require(lastSearch(backend))
        #expect(sent.query == "hello", "trimmed, and only once typing pauses")
        #expect(backend.sent.filter { if case .searchChat = $0 { true } else { false } }.count == 1)

        answer(model, first, ids: ["a"])
        #expect(model.search.chat?.ids.isEmpty == true)

        answer(model, sent.request, ids: ["b", "c"], truncated: true)
        #expect(model.search.chat?.ids == ["b", "c"])
        #expect(model.search.chat?.hits.map(\.id) == ["b", "c"])
        #expect(model.search.chat?.truncated == true)
        #expect(model.search.chat?.pending == false)
    }

    @Test func aSenderAKindOrADayListsOnItsOwn() async throws {
        let (model, backend) = model()
        model.selectedChatID = chat
        model.openChatSearch()

        model.setChatSearchSender(.person("farhod@s.whatsapp.net"))
        #expect(model.search.chat?.isAsking == true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(lastSearch(backend)?.sender == .person(id: "farhod@s.whatsapp.net"))
        #expect(lastSearch(backend)?.query == "")

        model.setChatSearchKind(.photos)
        try await Task.sleep(for: .milliseconds(50))
        #expect(lastSearch(backend)?.kind == .photos)
        #expect(lastSearch(backend)?.sender == .person(id: "farhod@s.whatsapp.net"), "filters add up")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        model.setChatSearchDay(Date(timeIntervalSince1970: 1_700_000_000), calendar: calendar)
        try await Task.sleep(for: .milliseconds(50))
        #expect(lastSearch(backend)?.from == 1_699_920_000)
        #expect(lastSearch(backend)?.until == 1_700_006_400)

        model.setChatSearchDay(nil)
        model.setChatSearchKind(nil)
        model.setChatSearchSender(nil)
        #expect(model.search.chat?.isAsking == false)
        #expect(model.search.chat?.ids.isEmpty == true)
    }

    @Test func pickingASenderTypesNamesNotWords() {
        let (model, _) = model()
        model.selectedChatID = chat
        model.openChatSearch()
        model.setChatSearchQuery("narx")
        model.beginPickingChatSearchSender()
        model.setChatSearchQuery("Far")
        #expect(model.search.chat?.senderText == "Far")
        #expect(model.search.chat?.query == "narx", "the words wait")
        #expect(model.search.chat?.fieldText == "Far")
        model.setChatSearchSender(.me)
        #expect(model.search.chat?.pickingSender == false)
        #expect(model.search.chat?.fieldText == "narx")
        #expect(model.search.chat?.sender == .me)
    }

    @Test func theArrowsWalkFromNewestToOldestAndStop() async throws {
        let (model, backend) = model()
        model.selectedChatID = chat
        model.apply([.messages(chat: chat, messages: [message("a", at: 1), message("b", at: 2)], older: false, complete: true)])
        model.openChatSearch()
        model.setChatSearchQuery("hello")
        answer(model, try await sentSearch(backend), ids: ["b", "a"])

        model.stepChatSearch(older: true)
        #expect(model.jump?.key.message == "b")
        #expect(model.search.chat?.currentID == "b")
        model.stepChatSearch(older: true)
        model.stepChatSearch(older: true)
        #expect(model.jump?.key.message == "a")
        model.stepChatSearch(older: false)
        #expect(model.search.chat?.current == 0)
    }

    @Test func aRefinedAnswerKeepsTheMatchOnScreen() async throws {
        let (model, backend) = model()
        model.selectedChatID = chat
        model.openChatSearch()
        model.setChatSearchQuery("he")
        answer(model, try await sentSearch(backend), ids: ["c", "b", "a"])
        model.revealChatSearchHit(1)
        model.setChatSearchQuery("hello")
        answer(model, try await sentSearch(backend, after: 1), ids: ["d", "b"])
        #expect(model.search.chat?.currentID == "b")
        #expect(model.search.chat?.current == 1)
    }

    @Test func theCalendarGoesToADaysFirstMessage() {
        let (model, backend) = model()
        model.selectedChatID = chat
        model.apply([.messages(chat: chat, messages: [message("a", at: 15), message("b", at: 35)], older: false, complete: true)])
        model.openChatSearch()
        model.askChatSearchDays([0, 10, 20, 30, 40])
        #expect(backend.sent.last == .chatDays(chat: chat, starts: [0, 10, 20, 30, 40]))
        model.apply([.chatDays(chat: chat, starts: [0, 10, 20, 30], first: [nil, "a", nil, "b"])])
        #expect(model.search.chat?.days[10] == .some("a"))
        #expect(model.search.chat?.days[0] == .some(nil), "known to have none")

        // Asked once: every day of the span is known now.
        let sent = backend.sent.count
        model.askChatSearchDays([0, 10, 20, 30, 40])
        #expect(backend.sent.count == sent)

        model.jumpToChatSearchDay(30)
        #expect(model.jump?.key.message == "b")
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

    @Test func snippetMarksWordsAcrossScriptsAndApostrophes() {
        let snippet = SearchSnippet.make("Ўзбекистон va oʻzbek tili", matching: "o'zbek")
        let bold = snippet.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(bold.map { String(snippet[$0.range].characters) } == ["Ўзбек", "oʻzbek"])
    }

    @Test func snippetMarksEveryWordInAnyOrder() {
        let snippet = SearchSnippet.make("Oem ni arzonroq bermasmikan", matching: "arzon oem")
        let bold = snippet.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(bold.map { String(snippet[$0.range].characters) } == ["Oem", "arzon"])
    }

    @Test func snippetCutsALongLeadSoTheMatchShows() {
        let text = String(repeating: "word ", count: 40) + "needle at the end"
        let snippet = String(SearchSnippet.make(text, matching: "needle").characters)
        #expect(snippet.hasPrefix("…"))
        #expect(snippet.contains("needle at the end"))
        #expect(snippet.count < 60)
    }
}
