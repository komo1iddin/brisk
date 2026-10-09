import Foundation

/// When to ask the phone for a chat's older messages.
///
/// A chat the phone has nothing older for is remembered by the backend, in
/// the archive (`chats.history_start`), and answered from there at once; for
/// the rest of the session the conversation's `phoneExhausted` stops the
/// asking, as upstream does. What remains here is a phone that does not
/// answer: each scroll to the top asked again, with the spinner turning for
/// the thirty seconds a request is given, so such a chat is left alone for
/// five minutes.
@MainActor
final class PhoneHistory {
    /// Where an earlier version kept chats it would not ask for three days.
    private static let retiredKey = "phoneHistoryExhausted"
    private let unansweredFor: TimeInterval = 5 * 60
    /// Messages held when the phone was asked, per chat.
    private var asked: [String: Int] = [:]
    private var quietUntil: [String: Date] = [:]

    init(defaults: UserDefaults) {
        // The archive knows a chat's start now; the three-day guess also held
        // back chats whose phone had merely sent an empty answer.
        defaults.removeObject(forKey: Self.retiredKey)
    }

    func mayAsk(_ chat: String, now: Date = .now) -> Bool {
        guard let until = quietUntil[chat] else { return true }
        return now >= until
    }

    func asking(_ chat: String, holding count: Int) {
        asked[chat] = count
    }

    /// The phone's answer, or the backend giving up waiting for one.
    func answered(_ chat: String, more: Bool, holding count: Int, now: Date = .now) {
        let before = asked.removeValue(forKey: chat)
        if more, let before, count <= before {
            // Nothing came: the request timed out or the phone is offline.
            quietUntil[chat] = now.addingTimeInterval(unansweredFor)
        } else {
            quietUntil[chat] = nil
        }
    }

    /// Forgets everything, for a new link.
    func clear() {
        asked = [:]
        quietUntil = [:]
    }
}
