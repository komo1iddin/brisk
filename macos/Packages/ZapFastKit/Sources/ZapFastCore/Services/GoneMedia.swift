import CryptoKit
import Foundation

/// Files the phone said it no longer has, remembered across launches so a later
/// download of the chat does not ask for them again. A file the phone has lost
/// does not come back, and each request to it costs a round trip.
///
/// Kept as short hashes of the chat and message, never as ids, and capped: the
/// oldest forgotten first.
@MainActor
final class GoneMedia {
    private let defaults: UserDefaults
    private let key = "goneMedia"
    static let limit = 10_000
    private var order: [String]
    private var known: Set<String>
    private var saving: Task<Void, Never>?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        order = defaults.stringArray(forKey: key) ?? []
        known = Set(order)
    }

    func contains(chat: String, message: String) -> Bool {
        known.contains(Self.hash(chat: chat, message: message))
    }

    func insert(chat: String, message: String) {
        let hash = Self.hash(chat: chat, message: message)
        guard known.insert(hash).inserted else { return }
        order.append(hash)
        if order.count > Self.limit {
            for forgotten in order.prefix(order.count - Self.limit) { known.remove(forgotten) }
            order.removeFirst(order.count - Self.limit)
        }
        // A run finds files gone one after another: written once it pauses.
        saving = saving ?? Task {
            try? await Task.sleep(for: .seconds(1))
            save()
        }
    }

    /// Writes what is remembered now.
    func save() {
        saving?.cancel()
        saving = nil
        defaults.set(order, forKey: key)
    }

    /// Forgets everything, for a new link.
    func clear() {
        saving?.cancel()
        saving = nil
        order = []
        known = []
        defaults.removeObject(forKey: key)
    }

    static func hash(chat: String, message: String) -> String {
        SHA256.hash(data: Data("\(chat)|\(message)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
