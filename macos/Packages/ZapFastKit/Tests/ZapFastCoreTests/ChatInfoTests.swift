import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct ChatInfoTests {
    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-info-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        return (model, backend)
    }

    private func group(_ participants: [String]) -> ChatSummary {
        ChatSummary(
            id: "g@g.us", name: "Team", groupSubjectKnown: true, kind: .group, lastActivity: 1, unread: 0,
            markedUnread: false, archived: false, pinned: false, pinnedAt: 0, mutedUntil: nil, last: nil,
            favorite: false, favoritePosition: 0, participants: participants, readOnly: false, left: false,
            infoLocked: nil, admin: false, locked: false, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: false, looksUnread: false, phone: nil
        )
    }

    private func contact(_ id: String, name: String) -> ContactRecord {
        ContactRecord(id: id, fullName: name, firstName: nil, pushName: nil)
    }

    @Test func membersListNamesAlphabeticallyThenNumbersThenUs() {
        let (model, _) = model()
        model.apply([
            .me(id: "999@s.whatsapp.net", lid: nil, name: "Me", about: nil),
            .contacts(contacts: [contact("1@s.whatsapp.net", name: "zafar"), contact("2@s.whatsapp.net", name: "Anvar")]),
        ])
        let chat = group(["999@s.whatsapp.net", "3@s.whatsapp.net", "1@s.whatsapp.net", "2@s.whatsapp.net"])

        let names = model.chats.members(of: chat).map(\.name)
        #expect(names.first == "Anvar")
        #expect(names[1] == "zafar")
        #expect(names.last == "You")
        #expect(names.count == 4)
    }

    @Test func infoOpensOverTheSearchAndSearchingClosesIt() {
        let (model, _) = model()
        model.selectedChatID = "g@g.us"
        model.openChatSearch()
        model.showInfo()
        // The search sits beside the chat; the info is over it.
        #expect(model.search.chat?.chat == "g@g.us")
        #expect(model.infoChat == "g@g.us")

        // The info's Search closes the info.
        model.openChatSearch()
        #expect(!model.infoShown)
        model.showInfo()
        model.selectedChatID = "other@s.whatsapp.net"
        #expect(model.search.chat == nil)
        #expect(!model.infoShown)
    }

    @Test func messagingSomeoneWithoutAChatCreatesItFirst() {
        let (model, backend) = model()
        model.startChat(with: "5@s.whatsapp.net")
        #expect(backend.sent.contains { if case .ensureChat(chat: "5@s.whatsapp.net", _) = $0 { true } else { false } })
        #expect(model.selectedChatID == "5@s.whatsapp.net")
    }

    @Test func fullPicturesAreAskedForOnceApartFromThumbnails() {
        let (model, backend) = model()
        _ = model.avatars.url(for: "5@s.whatsapp.net")
        _ = model.avatars.fullURL(for: "5@s.whatsapp.net")
        _ = model.avatars.fullURL(for: "5@s.whatsapp.net")
        #expect(backend.sent.filter { $0 == .fetchAvatar(id: "5@s.whatsapp.net", full: true) }.count == 1)

        model.apply([.avatar(id: "5@s.whatsapp.net", full: true, path: "/tmp/full.jpg")])
        #expect(model.avatars.fullURL(for: "5@s.whatsapp.net")?.path == "/tmp/full.jpg")
        #expect(model.avatars.url(for: "5@s.whatsapp.net") == nil)
    }
}
