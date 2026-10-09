import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct NewChatTests {
    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-newchat-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        model.apply([
            .me(id: "999@s.whatsapp.net", lid: nil, name: "Me", about: nil),
            .contacts(contacts: [
                ContactRecord(id: "1@s.whatsapp.net", fullName: "Zarina", firstName: nil, pushName: nil),
                ContactRecord(id: "2@s.whatsapp.net", fullName: "Anvar", firstName: nil, pushName: nil),
                ContactRecord(id: "999@s.whatsapp.net", fullName: "Me", firstName: nil, pushName: nil),
                ContactRecord(id: "x@lid", fullName: "No number", firstName: nil, pushName: nil),
            ]),
        ])
        return (model, backend)
    }

    @Test func candidatesAreContactsWithNumbersByNameWithoutUs() {
        let (model, _) = model()
        #expect(model.chats.newChatCandidates(query: "").map(\.name) == ["Anvar", "Zarina"])
        #expect(model.chats.newChatCandidates(query: "zar").map(\.id) == ["1@s.whatsapp.net"])
        #expect(model.chats.newChatCandidates(query: "2").map(\.id) == ["2@s.whatsapp.net"])
    }

    @Test func theChatListSearchFindsPeopleWithoutAChat() {
        let (model, _) = model()
        #expect(model.chats.matchingContacts(query: "").isEmpty, "nothing typed, nobody listed")
        #expect(model.chats.matchingContacts(query: "a").map(\.name) == ["Anvar", "Zarina"])
        model.apply([.chats(chats: [ChatSummary(
            id: "2@s.whatsapp.net", name: "Anvar", groupSubjectKnown: true, kind: .direct, lastActivity: 1, unread: 0,
            markedUnread: false, archived: false, pinned: false, pinnedAt: 0, mutedUntil: nil, last: nil,
            favorite: false, favoritePosition: 0, participants: [], readOnly: false, left: false,
            infoLocked: nil, admin: false, locked: false, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: false, looksUnread: false, phone: nil
        )])])
        #expect(model.chats.matchingContacts(query: "a").map(\.name) == ["Zarina"], "a chat lists Anvar already")
    }

    @Test func messageYourselfIsOfferedForItsWords() {
        let (model, _) = model()
        #expect(model.chats.offersSelf(query: ""))
        #expect(model.chats.offersSelf(query: "yours"))
        #expect(!model.chats.offersSelf(query: "zarina"))
    }

    @Test func aCheckedNumberOpensItsChat() {
        let (model, backend) = model()
        model.newChatShown = true
        model.newContact(phone: "+998 90 123", first: "Ali", last: "")
        model.newContact(phone: "998", first: "", last: "")
        #expect(backend.sent.filter { if case .newContact = $0 { true } else { false } }
            == [.newContact(phone: "99890123", fullName: "Ali", firstName: "Ali", toPhone: true)])

        model.apply([.contactReady(id: "99890123@s.whatsapp.net", name: "Ali")])
        #expect(!model.newContactPending)
        #expect(!model.newChatShown)
        #expect(model.selectedChatID == "99890123@s.whatsapp.net")
        #expect(backend.sent.contains(.ensureChat(chat: "99890123@s.whatsapp.net", name: "Ali")))
    }

    @Test func anUnknownNumberEndsTheCheck() {
        let (model, _) = model()
        model.newContact(phone: "123", first: "", last: "")
        model.apply([.error(message: "This number is not on WhatsApp")])
        #expect(!model.newContactPending)
    }
}
