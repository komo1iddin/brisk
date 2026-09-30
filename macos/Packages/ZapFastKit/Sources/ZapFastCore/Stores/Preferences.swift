import Foundation
import Observation
import ZapFastBridge

/// Interface preferences kept in `UserDefaults`. Settings that change what
/// the backend does live with the backend instead.
@Observable
public final class Preferences {
    @ObservationIgnored let defaults: UserDefaults

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

    /// Our own GIPHY key for GIF search; blank uses one built in, if any.
    public var giphyKey: String {
        didSet { defaults.set(giphyKey, forKey: Key.giphyKey) }
    }

    /// What a new message sounds like (upstream's default: its receive sound).
    public var messageSound: NotificationSoundInfo {
        didSet { defaults.set(messageSound.storageValue, forKey: Key.messageSound) }
    }

    /// What a mention of us or a reply to us sounds like.
    public var mentionSound: NotificationSoundInfo {
        didSet { defaults.set(mentionSound.storageValue, forKey: Key.mentionSound) }
    }

    /// Group messages make a sound; mentions of us always do.
    public var groupSounds: Bool {
        didSet { defaults.set(groupSounds, forKey: Key.groupSounds) }
    }

    /// Emoji picked from `:shortcode` completion, newest first (upstream's
    /// `recent_emoji`), offered first for a bare `:`.
    public internal(set) var recentEmoji: [String] {
        didSet { defaults.set(recentEmoji, forKey: Key.recentEmoji) }
    }

    /// Reactions sent and how often (upstream's `reaction_emoji`), most
    /// used first; the quick reactions and the picker's first row.
    public internal(set) var reactionEmoji: [ReactionUse] {
        didSet { defaults.set(try? JSONEncoder().encode(reactionEmoji), forKey: Key.reactionEmoji) }
    }

    /// Return sends; off, Return starts a new line and ⌘Return sends.
    public var enterSends: Bool {
        didSet { defaults.set(enterSends, forKey: Key.enterSends) }
    }

    /// Tell the chat we are typing while the composer changes.
    public var sendTyping: Bool {
        didSet { defaults.set(sendTyping, forKey: Key.sendTyping) }
    }

    /// Voice messages show who recorded them, as on the phone.
    public var voiceAvatars: Bool {
        didSet { defaults.set(voiceAvatars, forKey: Key.voiceAvatars) }
    }

    /// The app lock's password verifier (upstream's salted PBKDF2); nil
    /// leaves the lock off. The password itself is never kept.
    public var appLockVerifier: String? {
        didSet { defaults.set(appLockVerifier, forKey: Key.appLockVerifier) }
    }

    /// Minutes without using ZapFast before the app lock closes it.
    public var appLockAfter: AutoLock {
        didSet { defaults.set(appLockAfter.rawValue, forKey: Key.appLockAfter) }
    }

    /// Touch ID may open the app lock and locked chats instead of typing.
    public var unlockWithTouchID: Bool {
        didSet { defaults.set(unlockWithTouchID, forKey: Key.unlockWithTouchID) }
    }

    /// The verifier of the local code that opens locked chats; nil until set.
    public var chatLockVerifier: String? {
        didSet { defaults.set(chatLockVerifier, forKey: Key.chatLockVerifier) }
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
            Key.appLockAfter: AutoLock.fifteenMinutes.rawValue,
            Key.messageSound: NotificationSoundInfo.receive.storageValue,
            Key.mentionSound: NotificationSoundInfo.alert.storageValue,
            Key.groupSounds: true,
            Key.voiceAvatars: true,
            Key.enterSends: true,
            Key.sendTyping: true,
            Key.unlockWithTouchID: true,
        ])
        autoDownload = defaults.bool(forKey: Key.autoDownload)
        voiceSpeed = defaults.float(forKey: Key.voiceSpeed)
        sendReadReceipts = defaults.bool(forKey: Key.sendReadReceipts)
        notifications = defaults.bool(forKey: Key.notifications)
        notificationPreviews = defaults.bool(forKey: Key.notificationPreviews)
        saveContactsToPhone = defaults.bool(forKey: Key.saveContactsToPhone)
        giphyKey = defaults.string(forKey: Key.giphyKey) ?? ""
        messageSound = defaults.string(forKey: Key.messageSound).flatMap(NotificationSoundInfo.init(storage:)) ?? .receive
        mentionSound = defaults.string(forKey: Key.mentionSound).flatMap(NotificationSoundInfo.init(storage:)) ?? .alert
        groupSounds = defaults.bool(forKey: Key.groupSounds)
        voiceAvatars = defaults.bool(forKey: Key.voiceAvatars)
        recentEmoji = defaults.stringArray(forKey: Key.recentEmoji) ?? []
        enterSends = defaults.bool(forKey: Key.enterSends)
        reactionEmoji = defaults.data(forKey: Key.reactionEmoji)
            .flatMap { try? JSONDecoder().decode([ReactionUse].self, from: $0) } ?? []
        sendTyping = defaults.bool(forKey: Key.sendTyping)
        appLockVerifier = defaults.string(forKey: Key.appLockVerifier)
        appLockAfter = AutoLock(rawValue: defaults.integer(forKey: Key.appLockAfter)) ?? .fifteenMinutes
        unlockWithTouchID = defaults.bool(forKey: Key.unlockWithTouchID)
        chatLockVerifier = defaults.string(forKey: Key.chatLockVerifier)
    }

    private enum Key {
        static let autoDownload = "autoDownload"
        static let voiceSpeed = "voiceSpeed"
        static let sendReadReceipts = "sendReadReceipts"
        static let notifications = "notifications"
        static let notificationPreviews = "notificationPreviews"
        static let saveContactsToPhone = "saveContactsToPhone"
        static let giphyKey = "giphyKey"
        static let messageSound = "messageSound"
        static let mentionSound = "mentionSound"
        static let groupSounds = "groupSounds"
        static let voiceAvatars = "voiceAvatars"
        static let recentEmoji = "recentEmoji"
        static let enterSends = "enterSends"
        static let reactionEmoji = "reactionEmoji"
        static let sendTyping = "sendTyping"
        static let appLockVerifier = "appLockVerifier"
        static let appLockAfter = "appLockAfter"
        static let unlockWithTouchID = "unlockWithTouchID"
        static let chatLockVerifier = "chatLockVerifier"
    }
}

/// When the app lock closes ZapFast: WhatsApp Web's three choices, as
/// upstream offers them. The raw value is in seconds.
public enum AutoLock: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60
    case fifteenMinutes = 900
    case oneHour = 3600

    public var id: Int { rawValue }

    public var duration: Duration { .seconds(rawValue) }
}

public struct ReactionUse: Codable, Equatable, Sendable {
    public var emoji: String
    public var count: UInt32
}
