import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct LockedChatsTests {
    private let secret = "s@s.whatsapp.net"
    private let open = "o@s.whatsapp.net"

    private func model(code: String? = nil) -> (AppModel, PreviewBackend, Preferences) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-locked-\(UUID().uuidString)")
        let preferences = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        if let code { preferences.chatLockVerifier = chatLockVerifier(code: code) }
        let model = AppModel(backend: backend, paths: AppPaths(data: root, caches: root), preferences: preferences)
        model.apply([.chats(chats: [chat(secret, locked: true), chat(open, locked: false)])])
        return (model, backend, preferences)
    }

    private func chat(_ id: String, locked: Bool) -> ChatSummary {
        ChatSummary(
            id: id, name: "Chat", groupSubjectKnown: true, kind: .direct, lastActivity: 1, unread: 1,
            markedUnread: false, archived: false, pinned: false, pinnedAt: 0, mutedUntil: nil, last: nil,
            favorite: false, favoritePosition: 0, participants: [], readOnly: false, left: false,
            infoLocked: nil, admin: false, locked: locked, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: false, looksUnread: true, phone: nil
        )
    }

    @Test func lockedChatsStayOutOfTheListAndCounts() {
        let (model, _, _) = model()
        #expect(model.chats.visibleChats(filter: .all, query: "", archived: false).map(\.id) == [open])
        #expect(model.chats.lockedChats().map(\.id) == [secret])
        #expect(model.chats.unreadChatCount == 1)
    }

    @Test func theFolderOpensOnlyWithTheCode() async {
        let (model, _, _) = model(code: "2468")
        model.openLockedChats()
        #expect(model.lockedChatsPrompt)

        #expect(await !model.lockedChats.open(code: "1357"))
        #expect(model.lockedChats.wrongCode)
        #expect(await model.lockedChats.open(code: " 2468 "))
        model.lockedChatsOpened()
        #expect(model.lockedChats.isOpen && !model.lockedChatsPrompt)
    }

    @Test func leavingTheFolderLocksItAndClosesItsChat() async {
        let (model, _, _) = model(code: "2468")
        await model.lockedChats.open(code: "2468")
        model.selectedChatID = secret

        model.closeLockedChats()

        #expect(!model.lockedChats.isOpen)
        #expect(model.selectedChatID == nil)
    }

    @Test func theAppLockLocksTheFolderToo() async {
        let (model, _, preferences) = model(code: "2468")
        preferences.appLockVerifier = appLockVerifier(password: "password-1")
        await model.lockedChats.open(code: "2468")

        model.appLock.lock()

        #expect(!model.lockedChats.isOpen)
    }

    @Test func lockingTheOpenChatClosesItAndAsksForACodeTheFirstTime() {
        let (model, backend, _) = model()
        model.selectedChatID = open
        model.confirmLock(open)
        model.perform(model.chatConfirmation!)

        #expect(backend.sent.last == .setLocked(chat: open, locked: true))
        #expect(model.selectedChatID == nil)
        #expect(model.lockedChatsPrompt, "no code yet: set one up")
    }

    @Test func settingUpTheCodeOpensTheFolder() async {
        let (model, _, preferences) = model()
        await model.lockedChats.setUp(code: "1111")
        #expect(preferences.chatLockVerifier != nil)
        #expect(model.lockedChats.isOpen)

        #expect(await model.lockedChats.change(current: "0000", new: "2222", confirm: "2222") == .wrongCurrent)
        #expect(await model.lockedChats.change(current: "1111", new: "", confirm: "") == nil)
        #expect(preferences.chatLockVerifier == nil)
        #expect(!model.lockedChats.isOpen)
    }
}
