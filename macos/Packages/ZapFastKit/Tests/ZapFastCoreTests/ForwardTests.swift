import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct ForwardTests {
    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-forward-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        return (model, backend)
    }

    private func chat(
        _ id: String, name: String, kind: ChatKind = .direct, activity: Int64 = 1,
        readOnly: Bool = false, locked: Bool = false
    ) -> ChatSummary {
        ChatSummary(
            id: id, name: name, groupSubjectKnown: true, kind: kind, lastActivity: activity, unread: 0,
            markedUnread: false, archived: false, pinned: false, pinnedAt: 0, mutedUntil: nil, last: nil,
            favorite: false, favoritePosition: 0, participants: [], readOnly: readOnly, left: false,
            infoLocked: nil, admin: false, locked: locked, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: kind == .broadcast, looksUnread: false, phone: nil
        )
    }

    private func message(_ content: MessageContent) -> MessageRecord {
        MessageRecord(
            id: "m", chat: "a@g.us", sender: "x@s.whatsapp.net", senderName: nil, fromMe: false,
            timestamp: 1, content: content, status: .none, deliveredAt: nil, readAt: nil, quoted: nil,
            reactions: [], edited: false, mentions: [], forwarded: false, thumbnail: nil, summary: ""
        )
    }

    @Test func onlyChatsThatCanReceiveAreOfferedNewestFirst() {
        let (model, _) = model()
        model.apply([.chats(chats: [
            chat("old@g.us", name: "Old Group", kind: .group, activity: 1),
            chat("new@s.whatsapp.net", name: "New", activity: 9),
            chat("news@newsletter", name: "Channel", kind: .broadcast),
            chat("ann@g.us", name: "Announcements", kind: .group, readOnly: true),
            chat("secret@s.whatsapp.net", name: "Secret", locked: true),
        ])])

        #expect(model.chats.forwardTargets(query: "").map(\.id) == ["new@s.whatsapp.net", "old@g.us"])
        #expect(model.chats.forwardTargets(query: "grou").map(\.id) == ["old@g.us"])
    }

    @Test func revokedAndPollMessagesDoNotForward() {
        let (model, _) = model()
        #expect(model.canForward(message(.text(text: "hi", preview: nil))))
        #expect(!model.canForward(message(.revoked)))
        model.forward(message(.revoked))
        #expect(model.forwarding == nil)
    }

    @Test func pickingAChatSendsTheForward() {
        let (model, backend) = model()
        model.forward(message(.text(text: "hi", preview: nil)))
        model.forward(to: "b@s.whatsapp.net")
        #expect(backend.sent.last == .forward(fromChat: "a@g.us", messages: ["m"], toChat: "b@s.whatsapp.net"))
        #expect(model.forwarding == nil)
    }
}
