import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct AppLockTests {
    private let chat = "c@s.whatsapp.net"

    private func model(password: String? = nil) async -> (AppModel, PreviewBackend, Preferences) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-lock-\(UUID().uuidString)")
        let preferences = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        if let password { preferences.appLockVerifier = appLockVerifier(password: password) }
        let model = AppModel(backend: backend, paths: AppPaths(data: root, caches: root), preferences: preferences)
        return (model, backend, preferences)
    }

    private func summary(unread: UInt32) -> ChatSummary {
        ChatSummary(
            id: chat, name: "Chat", groupSubjectKnown: true, kind: .direct, lastActivity: 1, unread: unread,
            markedUnread: false, archived: false, pinned: false, pinnedAt: 0, mutedUntil: nil, last: nil,
            favorite: false, favoritePosition: 0, participants: [], readOnly: false, left: false,
            infoLocked: nil, admin: false, locked: false, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: false, looksUnread: unread > 0, phone: nil
        )
    }

    @Test func withoutAPasswordNothingLocks() async {
        let (model, _, _) = await model()
        #expect(!model.appLock.isLocked)
        model.appLock.lock()
        #expect(!model.appLock.isLocked)
    }

    @Test func aSetPasswordLocksAtStartAndOpensWithIt() async {
        let (model, _, _) = await model(password: "secret-1")
        #expect(model.appLock.isLocked)

        await model.appLock.unlock(password: "wrong-one")
        #expect(model.appLock.isLocked)
        #expect(model.appLock.wrongPassword)

        await model.appLock.unlock(password: "secret-1")
        #expect(!model.appLock.isLocked)
    }

    @Test func repeatedWrongPasswordsMakeTheNextTryWait() async {
        let (model, _, _) = await model(password: "secret-1")
        for _ in 0..<4 { await model.appLock.unlock(password: "nope-nope") }
        #expect(model.appLock.retryAt != nil)
        #expect(!model.appLock.canTry)
        await model.appLock.unlock(password: "secret-1")
        #expect(model.appLock.isLocked, "the wait is kept even for the right password")
    }

    @Test func nothingIsMarkedReadBehindTheLock() async {
        let (model, backend, _) = await model(password: "secret-1")
        model.selectedChatID = chat
        model.apply([.chatUpdated(chat: summary(unread: 2))])
        #expect(!backend.sent.contains { if case .markRead = $0 { true } else { false } })

        await model.appLock.unlock(password: "secret-1")
        model.apply([.chatUpdated(chat: summary(unread: 3))])
        #expect(backend.sent.contains { if case .markRead = $0 { true } else { false } })
    }

    @Test func settingsFollowUpstreamsForm() async {
        let (model, _, preferences) = await model()
        let lock = model.appLock
        #expect(await lock.submit(.set, current: "", new: "short", confirm: "short") == .tooShort)
        #expect(await lock.submit(.set, current: "", new: "long enough", confirm: "long enougH") == .mismatch)
        #expect(await lock.submit(.set, current: "", new: "long enough", confirm: "long enough") == nil)
        #expect(preferences.appLockVerifier != nil)
        #expect(!lock.isLocked, "setting a password does not lock at once")

        #expect(await lock.submit(.turnOff, current: "wrong", new: "", confirm: "") == .wrongCurrent)
        #expect(await lock.submit(.turnOff, current: "long enough", new: "", confirm: "") == nil)
        #expect(preferences.appLockVerifier == nil)
    }

    @Test func unlinkingForgetsThePasswordAndOpens() async {
        let (model, backend, preferences) = await model(password: "secret-1")
        model.unlinkToForgetPassword()
        #expect(backend.sent.last == .unlink)
        #expect(model.appLock.unlinking)

        model.apply([.link(state: .loggedOut)])
        #expect(!model.appLock.isLocked)
        #expect(preferences.appLockVerifier == nil)
    }
}
