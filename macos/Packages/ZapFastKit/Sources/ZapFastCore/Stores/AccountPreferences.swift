import Foundation
import Observation

/// Preferences that belong to one WhatsApp account, as upstream's
/// `AccountSettings`: receipts, typing, downloads, the last chat, and
/// notifications. Account 1 keeps the keys these had before there were
/// several accounts, so nothing moves; another account's keys carry its id.
@Observable
public final class AccountPreferences {
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let prefix: String

    /// Visible photos, videos, voice messages and documents download by
    /// themselves, as upstream does by default. Stickers always do.
    public var autoDownload: Bool {
        didSet { defaults.set(autoDownload, forKey: key(Key.autoDownload)) }
    }

    /// Send read receipts (and played receipts for voice messages).
    public var sendReadReceipts: Bool {
        didSet { defaults.set(sendReadReceipts, forKey: key(Key.sendReadReceipts)) }
    }

    /// Tell the chat we are typing while the composer changes.
    public var sendTyping: Bool {
        didSet { defaults.set(sendTyping, forKey: key(Key.sendTyping)) }
    }

    /// Desktop notifications for this account's new messages.
    public var notifications: Bool {
        didSet { defaults.set(notifications, forKey: key(Key.notifications)) }
    }

    /// Contacts saved here also go to the phone's address book.
    public var saveContactsToPhone: Bool {
        didSet { defaults.set(saveContactsToPhone, forKey: key(Key.saveContactsToPhone)) }
    }

    /// The chat open when ZapFast last ran, opened again at start
    /// (upstream's `last_chat`).
    public internal(set) var lastChat: String? {
        didSet { defaults.set(lastChat, forKey: key(Key.lastChat)) }
    }

    public init(account: String = "1", defaults: UserDefaults = .standard) {
        self.defaults = defaults
        prefix = account == "1" ? "" : "account.\(account)."
        let key = { [prefix] (name: String) in prefix + name }
        defaults.register(defaults: [
            key(Key.autoDownload): true,
            key(Key.sendReadReceipts): true,
            key(Key.sendTyping): true,
            key(Key.notifications): true,
            key(Key.saveContactsToPhone): true,
        ])
        autoDownload = defaults.bool(forKey: key(Key.autoDownload))
        sendReadReceipts = defaults.bool(forKey: key(Key.sendReadReceipts))
        sendTyping = defaults.bool(forKey: key(Key.sendTyping))
        notifications = defaults.bool(forKey: key(Key.notifications))
        saveContactsToPhone = defaults.bool(forKey: key(Key.saveContactsToPhone))
        lastChat = defaults.string(forKey: key(Key.lastChat))
    }

    /// Forgets a removed account's preferences.
    func forget() {
        for name in [Key.autoDownload, Key.sendReadReceipts, Key.sendTyping, Key.notifications,
                     Key.saveContactsToPhone, Key.lastChat] {
            defaults.removeObject(forKey: key(name))
        }
    }

    private func key(_ name: String) -> String { prefix + name }

    private enum Key {
        static let autoDownload = "autoDownload"
        static let sendReadReceipts = "sendReadReceipts"
        static let sendTyping = "sendTyping"
        static let notifications = "notifications"
        static let saveContactsToPhone = "saveContactsToPhone"
        static let lastChat = "lastChat"
    }
}
