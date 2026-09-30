import Foundation
import Observation
import Testing
import ZapFastBridge
@testable import ZapFastCore

/// A view that shows one chat is told about that chat only: the timeline
/// and the conversation's toolbar used to be rebuilt by every message,
/// download and name change in any chat.
@MainActor
struct StoreObservationTests {
    private func message(_ id: String, chat: String = "a", at time: Int64) -> MessageRecord {
        MessageRecord(
            id: id, chat: chat, sender: "s@s.whatsapp.net", senderName: nil, fromMe: false, timestamp: time,
            content: .text(text: id, preview: nil), status: .none, deliveredAt: nil, readAt: nil, quoted: nil,
            reactions: [], edited: false, mentions: [], forwarded: false, thumbnail: nil, summary: id
        )
    }

    /// Whether reading `read` is told about `change`.
    private func notified(reading read: () -> Void, after change: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking(read) { flag.fired = true }
        change()
        return flag.fired
    }

    /// Set from the observation callback, which runs synchronously here.
    private nonisolated final class Flag: @unchecked Sendable {
        var fired = false
    }

    @Test func aConversationIsNotToldAboutAnother() {
        let store = ConversationStore()
        store.applyMessages(chat: "a", messages: [message("1", at: 1)], older: false, complete: false)
        #expect(!notified(reading: { _ = store.conversation("a") }, after: {
            store.applyMessages(chat: "b", messages: [message("2", chat: "b", at: 2)], older: false, complete: false)
        }))
        #expect(notified(reading: { _ = store.conversation("a") }, after: {
            store.applyMessages(chat: "a", messages: [message("3", at: 3)], older: false, complete: false)
        }))
    }

    @Test func aDownloadIsToldOnlyAboutItself() {
        let store = ConversationStore()
        let mine = MessageKey(chat: "a", message: "1")
        #expect(!notified(reading: { _ = store.download(mine) }, after: {
            store.startDownload(MessageKey(chat: "a", message: "2"))
        }))
        #expect(notified(reading: { _ = store.download(mine) }, after: { store.startDownload(mine) }))
        #expect(store.download(mine) == .downloading)
    }

    @Test func pagingFlagsLeaveTheMessagesRevisionAlone() {
        let store = ConversationStore()
        store.applyMessages(chat: "a", messages: [message("2", at: 2)], older: false, complete: false)
        let before = store.conversation("a")
        store.markLoadingOlder("a")
        let loading = store.conversation("a")
        #expect(loading.revision != before.revision)
        #expect(loading.messagesRevision == before.messagesRevision)
        store.applyMessages(chat: "a", messages: [message("1", at: 1)], older: true, complete: true)
        #expect(store.conversation("a").messagesRevision != before.messagesRevision)
    }

    @Test func aChatOnlyLookedAtIsNotLoaded() {
        let store = ConversationStore()
        _ = store.conversation("a")
        // Updates for chats never loaded are ignored, as before slots.
        store.applyUpdated(message("1", at: 1))
        #expect(store.conversation("a").messages.isEmpty)
    }

    @Test func forgettingEmptiesTheChatForItsReaders() {
        let store = ConversationStore()
        store.applyMessages(chat: "a", messages: [message("1", at: 1)], older: false, complete: true)
        #expect(notified(reading: { _ = store.conversation("a") }, after: { store.forget("a") }))
        #expect(store.conversation("a").messages.isEmpty)
        store.applyUpdated(message("2", at: 2))
        #expect(store.conversation("a").messages.isEmpty)
    }

    @Test func mergeKeepsTimeOrder() {
        var conversation = Conversation()
        conversation.merge((1...20).map { message("\($0)", at: Int64($0) * 10) }, older: false)
        // A late message lands in its place; an update keeps its place.
        conversation.merge([message("late", at: 55)], older: false)
        conversation.merge([message("3", at: 30)], older: false)
        let times = conversation.messages.map(\.timestamp)
        #expect(times == times.sorted())
        #expect(conversation.messages.count == 21)
        #expect(conversation.messages[5].id == "late")
    }

    @Test func aChatIsNotToldAboutAnother() {
        let chats = ChatStore(session: SessionStore())
        chats.replaceAll([summary("a"), summary("b")])
        #expect(!notified(reading: { _ = chats.chat("a") }, after: { chats.upsert(summary("b", unread: 3)) }))
        #expect(notified(reading: { _ = chats.chat("a") }, after: { chats.upsert(summary("a", unread: 1)) }))
        #expect(chats.chat("a")?.unread == 1)
        chats.remove("a")
        #expect(chats.chat("a") == nil)
    }

    /// Typing in a busy group changes several times a second; each visible
    /// chat row and the open chat's header read their own chat's only.
    @Test func typingDraftsAndPresenceAreToldPerChat() {
        let conversations = ConversationStore()
        #expect(!notified(reading: { _ = conversations.typing(in: "a") }, after: {
            conversations.applyTyping(chat: "b", sender: "s", composing: true)
        }))
        #expect(notified(reading: { _ = conversations.typing(in: "a") }, after: {
            conversations.applyTyping(chat: "a", sender: "s", composing: true)
        }))
        #expect(conversations.typing(in: "a") == ["s"])
        #expect(!notified(reading: { _ = conversations.presence(of: "a") }, after: {
            conversations.applyPresence(id: "b", online: true, lastSeen: nil)
        }))
        #expect(notified(reading: { _ = conversations.presence(of: "a") }, after: {
            conversations.applyPresence(id: "a", online: true, lastSeen: nil)
        }))

        let chats = ChatStore(session: SessionStore())
        #expect(!notified(reading: { _ = chats.draft(for: "a") }, after: { chats.setDraft("hi", for: "b") }))
        #expect(notified(reading: { _ = chats.draft(for: "a") }, after: { chats.setDraft("hey", for: "a") }))
        #expect(chats.draft(for: "a") == "hey")
    }

    @Test func pinnedChatsAreCountedApart() {
        let chats = ChatStore(session: SessionStore())
        chats.replaceAll([summary("a", pinned: true), summary("b")])
        #expect(chats.pinnedCount == 1)
        #expect(!notified(reading: { _ = chats.pinnedCount }, after: { chats.upsert(summary("b", unread: 2)) }))
        chats.upsert(summary("b", pinned: true))
        #expect(chats.pinnedCount == 2)
    }

    /// The menu bar icon, the Dock badge and the filter menu read these;
    /// a message that leaves them as they were must not redraw them.
    @Test func unreadAndChannelCountsChangeOnlyWithTheirValue() {
        let chats = ChatStore(session: SessionStore())
        chats.replaceAll([summary("a", unread: 1), summary("b"), summary("c", channel: true, muted: true)])
        #expect(chats.unreadChatCount == 1)
        #expect(chats.channelCount == 1 && chats.mutedChannelCount == 1)
        #expect(!notified(reading: { _ = chats.unreadChatCount; _ = chats.channelCount }, after: {
            chats.upsert(summary("a", unread: 5))
        }))
        #expect(notified(reading: { _ = chats.unreadChatCount }, after: { chats.upsert(summary("b", unread: 1)) }))
        #expect(chats.unreadChatCount == 2)
        // Channels and muted chats never count toward the badge.
        chats.upsert(summary("c", unread: 9, channel: true))
        chats.upsert(summary("d", unread: 4, muted: true))
        #expect(chats.unreadChatCount == 2)
        #expect(chats.mutedChannelCount == 0)
    }

    @Test func theSidebarKeepsUpstreamsOrder() {
        let chats = ChatStore(session: SessionStore())
        var pinned = summary("p", pinned: true)
        pinned.pinnedAt = 5
        var older = summary("o")
        older.lastActivity = 10
        var newer = summary("n")
        newer.lastActivity = 20
        var tie = summary("m")
        tie.lastActivity = 20
        chats.replaceAll([older, newer, pinned, tie])
        let order = chats.visibleChats(filter: .all, query: "", archived: false).map(\.id)
        #expect(order == ["p", "m", "n", "o"])
    }

    @Test func daySeparatorsFollowTheCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        let start = Int64(calendar.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000)).timeIntervalSince1970)
        let times = [start + 60, start + 3_600, start + 86_399, start + 86_400, start + 3 * 86_400 + 5]
        let rows = TimelineRow.build(times.enumerated().map { message("\($0.offset)", at: $0.element) }, calendar: calendar)
        let days = rows.compactMap { row -> String? in if case .day(let id, _) = row { id } else { nil } }
        #expect(days == [start, start + 86_400, start + 3 * 86_400].map { "day-\($0)" })
    }

    private func summary(
        _ id: String, unread: UInt32 = 0, pinned: Bool = false, channel: Bool = false, muted: Bool = false
    ) -> ChatSummary {
        ChatSummary(
            id: id, name: id, groupSubjectKnown: true, kind: .direct, lastActivity: 0,
            unread: unread, markedUnread: false, archived: false, pinned: pinned, pinnedAt: 0, mutedUntil: muted ? 0 : nil,
            last: nil, favorite: false, favoritePosition: 0, participants: [], readOnly: false, left: false,
            infoLocked: nil, admin: false, locked: false, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: channel, looksUnread: unread > 0, phone: nil
        )
    }
}
