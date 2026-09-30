import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct SidebarTests {
    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-sidebar-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        model.apply([.chats(chats: [
            chat("read"), chat("unread", unread: 2),
            chat("news@newsletter", channel: true), chat("sport@newsletter", channel: true, mutedUntil: 0),
        ])])
        return (model, backend)
    }

    private func chat(_ id: String, unread: UInt32 = 0, channel: Bool = false, mutedUntil: Int64? = nil) -> ChatSummary {
        ChatSummary(
            id: id, name: id, groupSubjectKnown: true, kind: channel ? .broadcast : .direct, lastActivity: 1,
            unread: unread, markedUnread: false, archived: false, pinned: false, pinnedAt: 0,
            mutedUntil: mutedUntil, last: nil, favorite: false, favoritePosition: 0, participants: [],
            readOnly: false, left: false, infoLocked: nil, admin: false, locked: false,
            ephemeralExpiration: nil, labels: [], hasCustomSound: false, isChannel: channel,
            looksUnread: unread > 0, phone: nil
        )
    }

    @Test func aChatOpenedFromTheUnreadListStaysThereOnceRead() {
        let (model, _) = model()
        model.keepUnread("unread")
        #expect(model.keptUnread.isEmpty, "only while the sidebar shows Unread")

        model.sidebarKeepsUnread = true
        model.keepUnread("unread")
        model.apply([.chatUpdated(chat: chat("unread"))])
        let listed = model.chats.visibleChats(filter: .unread, query: "", archived: false, kept: model.keptUnread)
        #expect(listed.map(\.id) == ["unread"])

        model.forgetKeptUnread()
        #expect(model.chats.visibleChats(filter: .unread, query: "", archived: false, kept: model.keptUnread).isEmpty)
    }

    @Test func steppingThroughTheUnreadListKeepsItStill() {
        let (model, _) = model()
        model.sidebarKeepsUnread = true
        model.sidebarOrder = ["unread"]
        model.selectAdjacentChat(forward: true)
        #expect(model.keptUnread == ["unread"])
    }

    @Test func channelsAreMutedAndUnmutedTogether() {
        let (model, backend) = model()
        #expect(!model.allChannelsMuted)
        model.muteAllChannels(true)
        #expect(backend.sent.last == .setMuted(chat: "news@newsletter", until: 0))
        #expect(!backend.sent.contains(.setMuted(chat: "sport@newsletter", until: 0)), "already muted")

        model.apply([.chatUpdated(chat: chat("news@newsletter", channel: true, mutedUntil: 0))])
        #expect(model.allChannelsMuted)
        model.muteAllChannels(false)
        #expect(backend.sent.suffix(2).count == 2)
        #expect(backend.sent.contains(.setMuted(chat: "sport@newsletter", until: nil)))
    }
}
