import CryptoKit
import Foundation

/// When to ask the phone for a chat's older messages.
///
/// Upstream asks whenever the archive has run out and the reader is at the
/// top, and forgets the phone's answer when the app quits. A phone that has
/// nothing older, or does not answer, was asked again and again: each time
/// the timeline reached the top, and again at every launch, with the spinner
/// turning for the thirty seconds a request is given.
///
/// Here a chat the phone has nothing more for is not asked again for three
/// days, across launches, and one the phone did not answer is left alone for
/// five minutes. Chats are kept as hashes, never as numbers.
@MainActor
final class PhoneHistory {
    private let defaults: UserDefaults
    private let key = "phoneHistoryExhausted"
    private let exhaustedFor: TimeInterval = 3 * 24 * 3600
    private let unansweredFor: TimeInterval = 5 * 60
    /// Messages held when the phone was asked, per chat.
    private var asked: [String: Int] = [:]
    private var quietUntil: [String: Date] = [:]
    private var exhausted: [String: Double]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let now = Date().timeIntervalSince1970
        exhausted = (defaults.dictionary(forKey: key) as? [String: Double] ?? [:])
            .filter { now - $0.value < 3 * 24 * 3600 }
    }

    func mayAsk(_ chat: String, now: Date = .now) -> Bool {
        if let until = quietUntil[chat], now < until { return false }
        if let when = exhausted[Self.hash(chat)], now.timeIntervalSince1970 - when < exhaustedFor { return false }
        return true
    }

    func asking(_ chat: String, holding count: Int) {
        asked[chat] = count
    }

    /// The phone's answer, or the backend giving up waiting for one.
    func answered(_ chat: String, more: Bool, holding count: Int, now: Date = .now) {
        let before = asked.removeValue(forKey: chat)
        if !more {
            exhausted[Self.hash(chat)] = now.timeIntervalSince1970
            defaults.set(exhausted, forKey: key)
        } else if let before, count <= before {
            // Nothing came: the request timed out or the phone is offline.
            quietUntil[chat] = now.addingTimeInterval(unansweredFor)
        }
    }

    /// Forgets everything, for a new link.
    func clear() {
        asked = [:]
        quietUntil = [:]
        exhausted = [:]
        defaults.removeObject(forKey: key)
    }

    static func hash(_ chat: String) -> String {
        SHA256.hash(data: Data(chat.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
