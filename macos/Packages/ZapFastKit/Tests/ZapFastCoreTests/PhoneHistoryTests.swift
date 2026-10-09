import Foundation
import Testing
@testable import ZapFastCore

/// A phone that does not answer is not asked again at every scroll to the
/// top.
@MainActor
struct PhoneHistoryTests {
    private func defaults() -> UserDefaults {
        let name = "PhoneHistoryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theOldThreeDayMemoryIsForgotten() {
        let store = defaults()
        store.set(["0123456789abcdef01234567": 1_800_000_000.0], forKey: "phoneHistoryExhausted")
        let history = PhoneHistory(defaults: store)
        #expect(store.object(forKey: "phoneHistoryExhausted") == nil)
        #expect(history.mayAsk("a@s.whatsapp.net"))
    }

    @Test func nothingMoreIsLeftToTheArchiveAndTheConversation() {
        let history = PhoneHistory(defaults: defaults())
        let now = Date()
        history.asking("a", holding: 10)
        history.answered("a", more: false, holding: 10, now: now)
        // The backend answers from `history_start` at once; this session's
        // conversation keeps `phoneExhausted`.
        #expect(history.mayAsk("a", now: now))
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
