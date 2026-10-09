import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct ChatManagementTests {
    private let group = "g@g.us"
    private let direct = "d@s.whatsapp.net"

    private func model(connected: Bool = true) -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-manage-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        model.apply([.chats(chats: [chat(group, kind: .group), chat(direct, kind: .direct)])])
        if connected { model.apply([.link(state: .connected)]) }
        return (model, backend)
    }

    private func chat(_ id: String, kind: ChatKind) -> ChatSummary {
        ChatSummary(
            id: id, name: "Chat", groupSubjectKnown: true, kind: kind, lastActivity: 1, unread: 0,
            markedUnread: false, archived: false, pinned: false, pinnedAt: 0, mutedUntil: nil, last: nil,
            favorite: false, favoritePosition: 0, participants: [], readOnly: false, left: false,
            infoLocked: nil, admin: false, locked: false, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: false, looksUnread: false, phone: nil
        )
    }

    private func message(
        _ id: String, in chat: String, at time: Int64, fromMe: Bool = true, status: DeliveryState = .delivered
    ) -> MessageRecord {
        MessageRecord(
            id: id, chat: chat, sender: "me@s.whatsapp.net", senderName: nil, fromMe: fromMe,
            timestamp: time, content: .text(text: "hi", preview: nil), status: status,
            deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: nil, summary: "hi"
        )
    }

    private func receipts(for message: String) -> MessageReceiptsInfo {
        MessageReceiptsInfo(
            chat: group, message: message, recorded: true, audienceKnown: true,
            played: [], read: [], delivered: [], remaining: 2
        )
    }

    // MARK: Clearing and deleting

    @Test func clearingAndDeletingAskFirstThenGoToThePhone() {
        let (model, backend) = model()
        model.confirmClear(direct)
        #expect(model.chatConfirmation == ChatConfirmation(chat: direct, action: .clear))
        #expect(backend.sent.isEmpty)

        model.perform(model.chatConfirmation!)
        #expect(backend.sent.last == .clearChat(chat: direct))
        #expect(model.chatConfirmation == nil)

        model.confirmDelete(group)
        model.perform(model.chatConfirmation!)
        #expect(backend.sent.last == .deleteChat(chat: group))
    }

    @Test func offlineNothingIsOffered() {
        let (model, backend) = model(connected: false)
        model.confirmDelete(direct)
        #expect(model.chatConfirmation == nil)
        model.perform(ChatConfirmation(chat: direct, action: .delete))
        #expect(backend.sent.isEmpty)
    }

    @Test func aClearedChatLetsGoOfWhatPointedIntoIt() {
        let (model, _) = model()
        model.selectedChatID = direct
        let old = message("a", in: direct, at: 10)
        model.apply([.messages(chat: direct, messages: [old, message("b", in: direct, at: 30)], older: false, complete: false)])
        model.reply(to: old)
        model.confirmClear(direct)

        model.apply([.chatCleared(chat: direct, through: 20)])

        let conversation = model.conversations.conversation(direct)
        #expect(conversation.messages.map(\.id) == ["b"])
        #expect(conversation.complete && conversation.phoneExhausted)
        #expect(model.replyingTo[direct] == nil)
        #expect(model.chatConfirmation == nil, "a later clear would take what arrived since")
    }

    @Test func aDeletedChatClosesWithoutSavingADraft() {
        let (model, backend) = model()
        model.selectedChatID = direct
        model.composerText[direct] = "unsent"

        model.apply([.chatRemoved(chat: direct)])

        #expect(model.selectedChatID == nil)
        #expect(model.chats.chat(direct) == nil)
        #expect(model.composerText[direct] == nil)
        #expect(!backend.sent.contains { if case .saveDraft = $0 { true } else { false } })
    }

    // MARK: Message info

    @Test func infoIsForOurMessagesThatLeft() {
        let (model, _) = model()
        #expect(model.canShowInfo(message("a", in: direct, at: 1)))
        #expect(!model.canShowInfo(message("a", in: direct, at: 1, fromMe: false, status: .none)))
        #expect(!model.canShowInfo(message("a", in: direct, at: 1, status: .pending)))
        #expect(!model.canShowInfo(message("a", in: direct, at: 1, status: .failed)))
    }

    @Test func aGroupMessagesReceiptsAreFollowedOnlyWhileItsInfoIsOpen() {
        let (model, backend) = model()
        model.showInfo(message("m", in: group, at: 1))
        #expect(backend.sent.last == .watchReceipts(chat: group, message: "m"))

        model.apply([.receipts(receipts: receipts(for: "other"))])
        #expect(model.receipts == nil, "receipts for another message are ignored")
        model.apply([.receipts(receipts: receipts(for: "m"))])
        #expect(model.receipts?.remaining == 2)

        model.messageInfo = nil
        #expect(backend.sent.last == .stopWatchingReceipts)
        #expect(model.receipts == nil)
    }

    @Test func aDirectMessageNeedsNoFollowing() {
        let (model, backend) = model()
        model.showInfo(message("m", in: direct, at: 1))
        #expect(model.messageInfo == MessageKey(chat: direct, message: "m"))
        #expect(!backend.sent.contains { if case .watchReceipts = $0 { true } else { false } })
    }

    @Test func openingAnotherChatClosesTheInfo() {
        let (model, backend) = model()
        model.selectedChatID = group
        model.showInfo(message("m", in: group, at: 1))

        model.selectedChatID = direct

        #expect(model.messageInfo == nil)
        #expect(backend.sent.contains(.stopWatchingReceipts))
    }

    // MARK: Times

    @Test func momentsReadLikeUpstream() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let today = Int64(now.timeIntervalSince1970) - 60
        let yesterday = Int64(now.timeIntervalSince1970) - 86_400
        #expect(!DateText.moment(today, now: now, calendar: calendar).contains(" at "))
        #expect(DateText.moment(yesterday, now: now, calendar: calendar).hasPrefix("Yesterday at "))
    }

    @Test func daySeparatorsNameTheWeekdayAndTheYearOnlyWhenNotThisOne() {
        // Midday in the middle of a year, so no time zone moves the dates.
        let now = Date(timeIntervalSince1970: 1_783_771_200) // 2026-07-11 12:00 UTC
        let calendar = Calendar.current
        func day(daysAgo days: Double) -> (title: String, date: Date) {
            let date = now.addingTimeInterval(-days * 86_400)
            return (DateText.day(Int64(date.timeIntervalSince1970), now: now, calendar: calendar), date)
        }
        let thisYear = day(daysAgo: 30)
        #expect(thisYear.title.contains(thisYear.date.formatted(.dateTime.weekday(.abbreviated))), "\(thisYear.title)")
        #expect(!thisYear.title.contains("2026"), "\(thisYear.title)")
        let lastYear = day(daysAgo: 300)
        #expect(lastYear.title.contains(lastYear.date.formatted(.dateTime.weekday(.abbreviated))), "\(lastYear.title)")
        #expect(lastYear.title.contains("2025"), "\(lastYear.title)")
    }

    @Test func lastSeenNamesTheDayAndTheTimeAsThePhoneDoes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func seen(daysAgo days: Double, minutes: Double = 0) -> String {
            DateText.lastSeen(now.addingTimeInterval(-days * 86_400 - minutes * 60), now: now, calendar: calendar)
        }
        #expect(seen(daysAgo: 0, minutes: 5).hasPrefix("last seen today at "))
        // A clock a little ahead of ours still means today.
        #expect(seen(daysAgo: 0, minutes: -5).hasPrefix("last seen today at "))
        #expect(seen(daysAgo: 1).hasPrefix("last seen yesterday at "))
        // Within the week: a weekday and the time, in neither of the words above.
        for days in [2.0, 6.0] {
            let line = seen(daysAgo: days)
            #expect(line.hasPrefix("last seen ") && line.contains(" at "), "\(line)")
            #expect(!line.contains("today") && !line.contains("yesterday"), "\(line)")
        }
        // Before that, only the date.
        let old = seen(daysAgo: 7)
        #expect(old.hasPrefix("last seen ") && !old.contains(" at "), "\(old)")
    }

    @Test func earlierMessagesAreAskedForOnceAndNotWhileOffline() {
        let (model, backend) = model()
        let anchor = message("b", in: direct, at: 30)
        model.apply([.messages(chat: direct, messages: [anchor], older: false, complete: true)])
        model.apply([.olderFetched(chat: direct, more: false)])
        #expect(model.canReloadHistory(anchor))
        model.reloadHistory(before: anchor)
        // Asked even though the phone said the chat has nothing older.
        #expect(backend.sent.last == .reloadHistory(chat: direct, message: "b"))
        let count = backend.sent.count
        model.reloadHistory(before: anchor)
        #expect(backend.sent.count == count, "one request at a time")
        #expect(!model.canReloadHistory(message("p", in: direct, at: 40, status: .pending)))

        let (offline, _) = self.model(connected: false)
        #expect(!offline.canReloadHistory(anchor))
    }

}
