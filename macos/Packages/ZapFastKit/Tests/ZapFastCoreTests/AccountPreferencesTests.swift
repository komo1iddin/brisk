import Foundation
import Testing
@testable import ZapFastCore

/// Each account keeps its own receipts, typing, downloads, notifications and
/// last chat, as upstream's `AccountSettings`; account 1 keeps the old keys.
@MainActor
struct AccountPreferencesTests {
    private func defaults() -> UserDefaults {
        let name = "AccountPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theFirstAccountReadsWhatWasSavedBeforeThereWereSeveral() {
        let store = defaults()
        store.set(false, forKey: "sendReadReceipts")
        store.set("c@s.whatsapp.net", forKey: "lastChat")
        let first = AccountPreferences(account: "1", defaults: store)
        #expect(!first.sendReadReceipts)
        #expect(first.lastChat == "c@s.whatsapp.net")
        #expect(first.autoDownload && first.notifications && first.sendTyping && first.saveContactsToPhone)
    }

    @Test func anotherAccountHasItsOwnAndForgetsThemWhenRemoved() {
        let store = defaults()
        let first = AccountPreferences(account: "1", defaults: store)
        let second = AccountPreferences(account: "2", defaults: store)
        second.notifications = false
        second.lastChat = "g@g.us"
        #expect(first.notifications)
        #expect(first.lastChat == nil)
        let again = AccountPreferences(account: "2", defaults: store)
        #expect(!again.notifications && again.lastChat == "g@g.us")
        again.forget()
        let fresh = AccountPreferences(account: "2", defaults: store)
        #expect(fresh.notifications && fresh.lastChat == nil)
    }
}
