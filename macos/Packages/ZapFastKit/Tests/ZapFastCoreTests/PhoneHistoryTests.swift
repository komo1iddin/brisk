import Foundation
import Testing
@testable import ZapFastCore

/// The phone is asked for older messages once, not at every scroll to the
/// top or every launch.
@MainActor
struct PhoneHistoryTests {
    private func defaults() -> UserDefaults {
        let name = "PhoneHistoryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func nothingMoreIsRememberedAcrossLaunches() {
        let store = defaults()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = PhoneHistory(defaults: store)
        #expect(history.mayAsk("a@s.whatsapp.net", now: now))
        history.asking("a@s.whatsapp.net", holding: 10)
        history.answered("a@s.whatsapp.net", more: false, holding: 10, now: now)
        #expect(!history.mayAsk("a@s.whatsapp.net", now: now))
        // Kept as a hash, not the number.
        let saved = store.dictionary(forKey: "phoneHistoryExhausted") ?? [:]
        #expect(!saved.keys.contains { $0.contains("s.whatsapp.net") })
        // A later launch.
        let later = PhoneHistory(defaults: store)
        #expect(!later.mayAsk("a@s.whatsapp.net", now: now.addingTimeInterval(3600)))
        #expect(later.mayAsk("a@s.whatsapp.net", now: now.addingTimeInterval(4 * 24 * 3600)))
        #expect(later.mayAsk("b@s.whatsapp.net", now: now))
    }

    @Test func anUnansweredRequestWaitsBeforeTheNext() {
        let history = PhoneHistory(defaults: defaults())
        let now = Date()
        history.asking("a", holding: 5)
        history.answered("a", more: true, holding: 5, now: now)
        #expect(!history.mayAsk("a", now: now.addingTimeInterval(60)))
        #expect(history.mayAsk("a", now: now.addingTimeInterval(6 * 60)))
        // An answer that brought messages leaves the chat free to ask again.
        history.asking("b", holding: 5)
        history.answered("b", more: true, holding: 55, now: now)
        #expect(history.mayAsk("b", now: now))
    }
}
