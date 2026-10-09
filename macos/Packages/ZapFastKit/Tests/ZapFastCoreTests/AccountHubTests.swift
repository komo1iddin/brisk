import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

/// Several accounts in one window, as upstream's: one on screen, the others
/// running unseen; removing waits for the backend, and the last only unlinks.
@MainActor
struct AccountHubTests {
    private func hub(_ ids: [String]) -> (AccountHub, [String: PreviewBackend]) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let preferences = Preferences(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-hub-\(UUID().uuidString)")
        let paths = AppPaths(data: root, caches: root)
        let shared = SharedServices(
            appLock: AppLock(preferences: preferences),
            themes: ThemeStore(defaults: defaults, wallpapersFolder: root),
            notifier: nil
        )
        var backends: [String: PreviewBackend] = [:]
        let models = ids.map { id in
            let backend = PreviewBackend()
            backends[id] = backend
            return AppModel(accountID: id, backend: backend, paths: paths, preferences: preferences, shared: shared)
        }
        let hub = AccountHub(models: models, shared: shared)
        hub.start()
        for model in models { model.apply([.link(state: .connected)]) }
        return (hub, backends)
    }

    private func chat(_ id: String, unread: UInt32) -> ChatSummary {
        ChatSummary(
            id: id, name: "Chat", groupSubjectKnown: true, kind: .direct, lastActivity: 1, unread: unread,
            markedUnread: false, archived: false, pinned: false, pinnedAt: 0, mutedUntil: nil, last: nil,
            favorite: false, favoritePosition: 0, participants: [], readOnly: false, left: false,
            infoLocked: nil, admin: false, locked: false, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: false, looksUnread: unread > 0, phone: nil
        )
    }

    @Test func onlyTheAccountOnScreenIsOnline() {
        let (hub, backends) = hub(["1", "2"])
        #expect(hub.active.accountID == "1")
        #expect(hub.model("1")?.isOnScreen == true)
        #expect(hub.model("2")?.isOnScreen == false)

        hub.setActive(true)
        #expect(backends["1"]?.sent.last == .setOnline(online: true))
        #expect(backends["2"]?.sent.contains(.setOnline(online: true)) == false, "an account not shown is not online")

        var shown: [String] = []
        hub.onActiveChanged = { shown.append($0.accountID) }
        hub.switchTo("2")
        #expect(shown == ["2"])
        #expect(hub.active.accountID == "2")
        #expect(backends["1"]?.sent.last == .setOnline(online: false))
        #expect(backends["2"]?.sent.last == .setOnline(online: true))
    }

    @Test func theDotCountsOtherAccountsUnreadChats() {
        let (hub, _) = hub(["1", "2"])
        hub.model("1")?.apply([.chats(chats: [chat("a@s.whatsapp.net", unread: 2)])])
        hub.model("2")?.apply([.chats(chats: [chat("b@s.whatsapp.net", unread: 1), chat("c@s.whatsapp.net", unread: 4)])])
        #expect(hub.unreadEverywhere == 3)
        #expect(hub.unreadElsewhere == 2)
        hub.switchTo("2")
        #expect(hub.unreadElsewhere == 1)
    }

    @Test func aRemovedAccountGoesOnceItsBackendHasStopped() {
        let (hub, backends) = hub(["1", "2"])
        hub.switchTo("2")
        var removed: [String] = []
        hub.onModelRemoved = { removed.append($0.accountID) }

        hub.remove("2")
        #expect(backends["2"]?.sent.last == .removeAccount)
        #expect(hub.models.count == 2, "still there until the backend says it stopped")

        hub.model("2")?.apply([.accountRemoved])
        #expect(hub.models.map(\.accountID) == ["1"])
        #expect(hub.active.accountID == "1")
        #expect(hub.active.isOnScreen)
        #expect(removed == ["2"])
    }

    @Test func theLastAccountIsOnlyUnlinked() {
        let (hub, backends) = hub(["1"])
        hub.remove("1")
        #expect(backends["1"]?.sent.last == .unlink)
        #expect(hub.models.count == 1)
    }

    @Test func theAppLockLocksEveryAccount() {
        let (hub, backends) = hub(["1", "2"])
        hub.setActive(true)
        hub.preferences.appLockVerifier = "x"
        hub.shared.appLock.lock()
        #expect(backends["1"]?.sent.last == .setOnline(online: false))
    }

    @Test func theAppPasswordIsForgottenOnlyWhenNoAccountIsLinked() {
        let (hub, _) = hub(["1", "2"])
        hub.preferences.appLockVerifier = "x"
        hub.model("2")?.apply([.link(state: .loggedOut)])
        #expect(hub.preferences.appLockVerifier == "x", "account 1 is still linked")
        hub.model("1")?.apply([.link(state: .loggedOut)])
        #expect(hub.preferences.appLockVerifier == nil)
    }

}
