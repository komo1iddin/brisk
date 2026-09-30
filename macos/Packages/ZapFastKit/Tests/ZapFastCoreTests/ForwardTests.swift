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

    private func forwarded(_ id: String, to chat: String, status: DeliveryState) -> MessageRecord {
        MessageRecord(
            id: id, chat: chat, sender: "me@s.whatsapp.net", senderName: nil, fromMe: true,
            timestamp: Int64(Date.now.timeIntervalSince1970), content: .text(text: "hi", preview: nil),
            status: status, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: true, thumbnail: nil, summary: "hi"
        )
    }

    @Test func eachTickedChatGetsTheForwardInTurn() {
        let (model, backend) = model()
        model.forward(message(.text(text: "hi", preview: nil)))
        model.forward(to: ["b@s.whatsapp.net", "c@g.us"])
        #expect(backend.sent.suffix(2) == [
            .forward(fromChat: "a@g.us", messages: ["m"], toChat: "b@s.whatsapp.net"),
            .forward(fromChat: "a@g.us", messages: ["m"], toChat: "c@g.us"),
        ])
        #expect(model.forwardNotes.isEmpty)
    }

    @Test func anAddedMessageFollowsOnceTheForwardsHaveLeft() {
        let (model, backend) = model()
        model.forward(message(.text(text: "hi", preview: nil)))
        model.forward(to: ["b@s.whatsapp.net", "c@g.us"], note: "  look at this ")
        let note = BridgeCommand.sendText(chat: "b@s.whatsapp.net", text: "look at this", quoting: nil, mentions: [])

        // Stored, still on its way: the note waits.
        model.apply([.messages(chat: "b@s.whatsapp.net", messages: [forwarded("f1", to: "b@s.whatsapp.net", status: .pending)], older: false, complete: false)])
        #expect(!backend.sent.contains(note))
        // Another chat's forward leaving releases only that chat's note.
        model.apply([.messageUpdated(message: forwarded("f2", to: "c@g.us", status: .sent))])
        #expect(!backend.sent.contains(note))
        #expect(backend.sent.last == .sendText(chat: "c@g.us", text: "look at this", quoting: nil, mentions: []))
        #expect(model.forwardNotes.map(\.chat) == ["b@s.whatsapp.net"])

        model.apply([.messageUpdated(message: forwarded("f1", to: "b@s.whatsapp.net", status: .sent))])
        #expect(backend.sent.last == note)
        #expect(model.forwardNotes.isEmpty)
    }

    @Test func aNoteWhoseForwardsNeverCameGoesToThatComposer() {
        let (model, backend) = model()
        model.forward(message(.text(text: "hi", preview: nil)))
        model.forward(to: ["b@s.whatsapp.net"], note: "look")
        let id = model.forwardNotes[0].id
        model.forwardNoteExpired(id)
        #expect(model.forwardNotes.isEmpty)
        #expect(model.composerText["b@s.whatsapp.net"] == "look")
        #expect(!backend.sent.contains { if case .sendText = $0 { true } else { false } })
    }

    @Test func ourOwnChatIsOfferedFirstAndOnlyThere() {
        let (model, _) = model()
        model.apply([
            .me(id: "me@s.whatsapp.net", lid: nil, name: "Komil", about: nil),
            .chats(chats: [chat("me@s.whatsapp.net", name: "Komil", activity: 5)]),
        ])
        #expect(model.forwardSelfTarget(query: "") == "me@s.whatsapp.net")
        #expect(model.forwardSelfTarget(query: "zzz") == nil)
        #expect(model.forwardTargetName("me@s.whatsapp.net") == "Komil (You)")
    }

    @Test func pickingAChatSendsTheForward() {
        let (model, backend) = model()
        model.forward(message(.text(text: "hi", preview: nil)))
        model.forward(to: "b@s.whatsapp.net")
        #expect(backend.sent.last == .forward(fromChat: "a@g.us", messages: ["m"], toChat: "b@s.whatsapp.net"))
        #expect(model.forwarding == nil)
    }
}
