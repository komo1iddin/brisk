import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct SharedContactTests {
    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-contact-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        return (model, backend)
    }

    private func card(_ vcard: String) -> MessageRecord {
        MessageRecord(
            id: "c", chat: "a@s.whatsapp.net", sender: "a@s.whatsapp.net", senderName: nil, fromMe: false,
            timestamp: 1, content: .contact(displayName: "Sent name", vcard: vcard), status: .none,
            deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: nil, summary: "Contact"
        )
    }

    @Test func aCardNamesItsPersonNumberAndAccount() {
        let (model, _) = model()
        let contact = model.sharedContact(in: card(
            "BEGIN:VCARD\nVERSION:3.0\nFN:Alice Example\nitem1.TEL;waid=15550101234:+1 (555) 010-1234\nEND:VCARD"
        ))
        #expect(contact == SharedContact(name: "Alice Example", number: "+1 (555) 010-1234", account: "15550101234"))
        #expect(model.sharedContact(in: card("BEGIN:VCARD\nFN:No phone\nEND:VCARD")) == nil)
    }

    @Test func messageOpensTheAccountsChatAndAddSavesTheSplitName() {
        let (model, backend) = model()
        let contact = SharedContact(name: "Alice van Example", number: "+15550101234", account: "15550101234")
        model.chat(with: contact)
        #expect(model.selectedChatID == "15550101234@s.whatsapp.net")
        #expect(backend.sent.contains(.ensureChat(chat: "15550101234@s.whatsapp.net", name: "Alice van Example")))

        model.addContact(contact)
        #expect(backend.sent.last == .newContact(
            phone: "15550101234", fullName: "Alice van Example", firstName: "Alice", toPhone: true
        ))
        #expect(!model.isKnownContact("15550101234"))
    }
}
