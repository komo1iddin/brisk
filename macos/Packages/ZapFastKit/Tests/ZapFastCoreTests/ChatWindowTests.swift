import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct ChatWindowTests {
    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-window-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        model.apply([.chats(chats: [chat("a", unread: 2), chat("b")])])
        return (model, backend)
    }

    private func chat(_ id: String, unread: UInt32 = 0) -> ChatSummary {
        ChatSummary(
            id: id, name: id, groupSubjectKnown: true, kind: .direct, lastActivity: 1, unread: unread,
            markedUnread: false, archived: false, pinned: false, pinnedAt: 0, mutedUntil: nil, last: nil,
            favorite: false, favoritePosition: 0, participants: [], readOnly: false, left: false,
            infoLocked: nil, admin: false, locked: false, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: false, looksUnread: unread > 0, phone: nil
        )
    }

    @Test func aChatInItsOwnWindowIsOpenAndRead() {
        let (model, backend) = model()
        model.chatWindowAppeared("a")
        #expect(model.isOpen("a"))
        #expect(backend.sent.contains(.loadChat(chat: "a", before: nil)))
        #expect(backend.sent.contains { if case .markRead(chat: "a", _) = $0 { true } else { false } })

        // The main window moving on does not close the other window's chat.
        model.selectedChatID = "b"
        model.showInfo(in: "a")
        model.selectedChatID = nil
        #expect(model.isOpen("a"))
        #expect(model.infoChat == "a")

        model.chatWindowDisappeared("a")
        #expect(!model.isOpen("a"))
        #expect(model.infoChat == nil)
    }

    @Test func twoWindowsOfOneChatBothCount() {
        let (model, _) = model()
        model.chatWindowAppeared("b")
        model.chatWindowAppeared("b")
        model.chatWindowDisappeared("b")
        #expect(model.isOpen("b"))
        model.chatWindowDisappeared("b")
        #expect(!model.isOpen("b"))
    }
}
