import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct UnreadDividerTests {
    private let busy = "busy@s.whatsapp.net"
    private let quiet = "quiet@s.whatsapp.net"

    private func model() -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-unread-\(UUID().uuidString)")
        let model = AppModel(
            backend: PreviewBackend(),
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        model.apply([.chats(chats: [chat(busy, unread: 2), chat(quiet, unread: 0)])])
        return model
    }

    private func chat(_ id: String, unread: UInt32) -> ChatSummary {
        ChatSummary(
            id: id, name: "Chat", groupSubjectKnown: true, kind: .direct, lastActivity: 1, unread: unread,
            markedUnread: false, archived: false, pinned: false, pinnedAt: 0, mutedUntil: nil, last: nil,
            favorite: false, favoritePosition: 0, participants: [], readOnly: false, left: false,
            infoLocked: nil, admin: false, locked: false, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: false, looksUnread: unread > 0, phone: nil
        )
    }

    private func message(_ id: String, at time: Int64, fromMe: Bool = false) -> MessageRecord {
        MessageRecord(
            id: id, chat: busy, sender: fromMe ? "me@s.whatsapp.net" : busy, senderName: nil, fromMe: fromMe,
            timestamp: time, content: .text(text: "hi", preview: nil), status: .none,
            deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: nil, summary: "hi"
        )
    }

    @Test func theDividerSitsAboveTheFirstUnreadIncomingMessage() {
        let model = model()
        model.selectedChatID = busy
        #expect(model.unreadDivider == UnreadDivider(chat: busy, count: 2))

        // Our own reply between them does not count.
        let page = [message("a", at: 10), message("b", at: 20), message("mine", at: 25, fromMe: true), message("c", at: 30)]
        model.apply([.messages(chat: busy, messages: page, older: false, complete: true)])
        #expect(model.unreadDivider?.message == "b")

        let rows = TimelineRow.build(model.conversations.conversation(busy).messages, unread: model.unreadDivider)
        let ids = rows.map(\.id)
        #expect(ids.firstIndex(of: "unread") == ids.firstIndex(of: "b").map { $0 - 1 })
        if case .message(_, let startsRun, _) = rows[ids.firstIndex(of: "b")!] {
            #expect(startsRun, "the message under the divider starts a run")
        }
        if case .message(_, _, let endsRun) = rows[ids.firstIndex(of: "a")!] {
            #expect(endsRun, "the message above the divider ends one")
        }
    }

    @Test func aRunEndsBeforeAnotherSenderAPauseOrANewDay() {
        let other = "b@s.whatsapp.net"
        func from(_ sender: String, _ id: String, at time: Int64) -> MessageRecord {
            var record = message(id, at: time)
            record.sender = sender
            return record
        }
        let rows = TimelineRow.build([
            from(busy, "a1", at: 1_780_000_000), from(busy, "a2", at: 1_780_000_060),
            from(other, "b1", at: 1_780_000_120),
            // A pause of more than five minutes.
            from(other, "b2", at: 1_780_000_600),
            // The next day.
            from(other, "b3", at: 1_780_086_400),
        ])
        let runs = rows.compactMap { row -> (String, Bool, Bool)? in
            if case let .message(message, starts, ends) = row { (message.id, starts, ends) } else { nil }
        }
        #expect(runs.map(\.0) == ["a1", "a2", "b1", "b2", "b3"])
        #expect(runs.map(\.1) == [true, false, true, true, true])
        #expect(runs.map(\.2) == [false, true, true, true, true])
    }

    @Test func laterMessagesDoNotMoveIt() {
        let model = model()
        model.selectedChatID = busy
        model.apply([.messages(chat: busy, messages: [message("a", at: 10), message("b", at: 20)], older: false, complete: true)])
        model.apply([.messageUpdated(message: message("c", at: 30))])
        #expect(model.unreadDivider?.message == "a")
    }

    @Test func aCountPastTheLoadedPageShowsNone() {
        let model = model()
        model.selectedChatID = busy
        model.apply([.messages(chat: busy, messages: [message("a", at: 10)], older: false, complete: false)])
        #expect(model.unreadDivider == nil)
    }

    @Test func anotherChatWithoutUnreadClearsIt() {
        let model = model()
        model.selectedChatID = busy
        #expect(model.unreadDivider != nil)
        model.selectedChatID = quiet
        #expect(model.unreadDivider == nil)
        #expect(TimelineRow.build([message("a", at: 10)], unread: nil).allSatisfy { $0.id != "unread" })
    }
}
