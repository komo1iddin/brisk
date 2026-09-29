import Foundation
import Observation

/// Interface preferences kept in `UserDefaults`. Settings that change what
/// the backend does live with the backend instead.
@Observable
public final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    /// Visible photos, videos, voice messages and documents download by
    /// themselves, as upstream does by default. Stickers always do.
    public var autoDownload: Bool {
        didSet { defaults.set(autoDownload, forKey: Key.autoDownload) }
    }

    /// Voice message playback speed: 1, 1.5, or 2.
    public var voiceSpeed: Float {
        didSet { defaults.set(voiceSpeed, forKey: Key.voiceSpeed) }
    }

    /// Send read receipts (and played receipts for voice messages).
    public var sendReadReceipts: Bool {
        didSet { defaults.set(sendReadReceipts, forKey: Key.sendReadReceipts) }
    }

    /// Desktop notifications for new messages.
    public var notifications: Bool {
        didSet { defaults.set(notifications, forKey: Key.notifications) }
    }

    /// Show who wrote and what in notifications; off shows "New message".
    public var notificationPreviews: Bool {
        didSet { defaults.set(notificationPreviews, forKey: Key.notificationPreviews) }
    }

    /// Contacts saved here also go to the phone's address book.
    public var saveContactsToPhone: Bool {
        didSet { defaults.set(saveContactsToPhone, forKey: Key.saveContactsToPhone) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.autoDownload: true,
            Key.voiceSpeed: Float(1),
            Key.sendReadReceipts: true,
            Key.notifications: true,
            Key.notificationPreviews: true,
            Key.saveContactsToPhone: true,
        ])
        autoDownload = defaults.bool(forKey: Key.autoDownload)
        voiceSpeed = defaults.float(forKey: Key.voiceSpeed)
        sendReadReceipts = defaults.bool(forKey: Key.sendReadReceipts)
        notifications = defaults.bool(forKey: Key.notifications)
        notificationPreviews = defaults.bool(forKey: Key.notificationPreviews)
        saveContactsToPhone = defaults.bool(forKey: Key.saveContactsToPhone)
    }

    private enum Key {
        static let autoDownload = "autoDownload"
        static let voiceSpeed = "voiceSpeed"
        static let sendReadReceipts = "sendReadReceipts"
        static let notifications = "notifications"
        static let notificationPreviews = "notificationPreviews"
        static let saveContactsToPhone = "saveContactsToPhone"
    }
}
