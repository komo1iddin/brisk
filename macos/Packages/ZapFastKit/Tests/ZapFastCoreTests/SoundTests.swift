import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct SoundTests {
    private func preferences() -> Preferences {
        Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    @Test func upstreamsOrderPicksTheSound() {
        let settings = preferences()
        #expect(notificationSound(chat: nil, forUs: false, isGroup: false, preferences: settings) == .receive)
        #expect(notificationSound(chat: nil, forUs: true, isGroup: true, preferences: settings) == .alert)
        settings.groupSounds = false
        #expect(notificationSound(chat: nil, forUs: false, isGroup: true, preferences: settings) == .none)
        #expect(notificationSound(chat: nil, forUs: true, isGroup: true, preferences: settings) == .alert,
                "mentions sound even in quiet groups")
        #expect(notificationSound(chat: .system, forUs: true, isGroup: true, preferences: settings) == .system,
                "the chat's own sound wins")
    }

    @Test func soundsSurviveARestart() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = Preferences(defaults: defaults)
        first.messageSound = .custom(path: "/Sounds/ding.aiff")
        first.mentionSound = .none
        let second = Preferences(defaults: defaults)
        #expect(second.messageSound == .custom(path: "/Sounds/ding.aiff"))
        #expect(second.mentionSound == .none)
        #expect(second.groupSounds)
    }

    @Test func mentionsAndRepliesToUsAddressUs() {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-sound-\(UUID().uuidString)")
        let model = AppModel(backend: backend, paths: AppPaths(data: root, caches: root), preferences: preferences())
        model.apply([.me(id: "111@s.whatsapp.net", lid: "999@lid", name: nil, about: nil)])
        func message(mentions: [MentionInfo] = [], quoting sender: String? = nil) -> MessageRecord {
            MessageRecord(
                id: "m", chat: "g@g.us", sender: "b@s.whatsapp.net", senderName: nil, fromMe: false, timestamp: 1,
                content: .text(text: "hi", preview: nil), status: .none, deliveredAt: nil, readAt: nil,
                quoted: sender.map { QuotedMessage(id: "q", sender: $0, senderName: nil, summary: "", mentions: []) },
                reactions: [], edited: false, mentions: mentions, forwarded: false, thumbnail: nil, summary: "hi"
            )
        }
        #expect(!model.addressesUs(message()))
        #expect(model.addressesUs(message(mentions: [MentionInfo(user: "999", id: "someone@lid")])))
        #expect(model.addressesUs(message(quoting: "111@s.whatsapp.net")))
        #expect(!model.addressesUs(message(quoting: "c@s.whatsapp.net")))
    }

    @Test func aChatSoundGoesToTheArchive() {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-sound-\(UUID().uuidString)")
        let model = AppModel(backend: backend, paths: AppPaths(data: root, caches: root), preferences: preferences())
        model.setChatSound(.alert, chat: "c@s.whatsapp.net")
        #expect(backend.sent.last == .setChatSound(chat: "c@s.whatsapp.net", sound: .alert))
    }
}
