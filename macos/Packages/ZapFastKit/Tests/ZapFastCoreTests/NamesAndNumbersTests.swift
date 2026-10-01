import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore
import ZapFastDesign

@MainActor
struct NamesAndNumbersTests {
    private let group = "g@g.us"

    private func model(members: [String], connected: Bool = true) -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-names-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        model.apply([.chats(chats: [ChatSummary(
            id: group, name: "Group", groupSubjectKnown: true, kind: .group, lastActivity: 1, unread: 0,
            markedUnread: false, archived: false, pinned: false, pinnedAt: 0, mutedUntil: nil, last: nil,
            favorite: false, favoritePosition: 0, participants: members, readOnly: false, left: false,
            infoLocked: nil, admin: false, locked: false, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: false, looksUnread: false, phone: nil
        )])])
        if connected { model.apply([.link(state: .connected)]) }
        return (model, backend)
    }

    // MARK: Name colours

    @Test func everyMemberOfAGroupHasAColourOfTheirOwn() {
        let members = (0..<NameColors.count).map { "99890000\($0)@s.whatsapp.net" }
        let colors = NameColors.assign(members: members)
        #expect(Set(colors.values).count == NameColors.count)
        // The same members, in any order, the same colours.
        #expect(NameColors.assign(members: members.reversed()) == colors)
        // More members than colours start another round.
        let crowd = NameColors.assign(members: members + ["extra@s.whatsapp.net"])
        #expect(crowd.count == NameColors.count + 1)
        #expect(AppKitPalette.nameColorCount == NameColors.count)
    }

    @Test func aChatsColoursFollowItsMembers() {
        let members = ["a@s.whatsapp.net", "b@s.whatsapp.net", "c@s.whatsapp.net"]
        let (model, _) = model(members: members)
        let colors = members.map { model.chats.nameColor($0, in: group) }
        #expect(Set(colors).count == members.count)
        #expect(colors == members.map { NameColors.assign(members: members)[$0] })
        // Someone who left keeps the colour their id leads to.
        #expect(model.chats.nameColor("gone@s.whatsapp.net", in: group) == NameColors.hashed("gone@s.whatsapp.net"))
    }

    // MARK: Numbers

    @Test func numbersReadAsWhatsAppWritesThem() {
        #expect(PhoneFormat.display(id: "989370396614@s.whatsapp.net") == "+98 937 039 6614")
        #expect(PhoneFormat.display(id: "998901112233@s.whatsapp.net") == "+998 90 111 22 33")
        #expect(PhoneFormat.display(id: "5511912345678@s.whatsapp.net")?.hasPrefix("+55 11 ") == true)
        #expect(PhoneFormat.display(id: group) == nil)
        #expect(PhoneFormat.display(id: "123456789@lid") == nil)
    }

    @Test func turningNumbersOffKeepsThemOutOfNamesOnly() {
        let (model, _) = model(members: [])
        #expect(model.preferences.senderPhones)
        model.preferences.senderPhones = false
        // The setting only hides them beside names; the number is still known.
        #expect(model.chats.unsavedPhone("998901112233@s.whatsapp.net") == "+998 90 111 22 33")
    }
}
