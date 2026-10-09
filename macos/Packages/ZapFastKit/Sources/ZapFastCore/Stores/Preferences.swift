import Foundation
import Observation
import ZapFastBridge

/// Interface preferences kept in `UserDefaults`, the same for every account.
/// Those upstream keeps per account are `AccountPreferences`. Settings that
/// change what the backend does live with the backend instead.
@Observable
public final class Preferences {
    @ObservationIgnored let defaults: UserDefaults

    /// Voice message playback speed: 1, 1.5, or 2.
    public var voiceSpeed: Float {
        didSet { defaults.set(voiceSpeed, forKey: Key.voiceSpeed) }
    }

    /// Show who wrote and what in notifications; off shows "New message".
    public var notificationPreviews: Bool {
        didSet { defaults.set(notificationPreviews, forKey: Key.notificationPreviews) }
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

    /// Message text size, a multiple of the body size (upstream's `zoom`,
    /// for the text of the chats): 0.8 to 1.6 in tenths.
    public var textScale: Double {
        didSet { defaults.set(textScale, forKey: Key.textScale) }
    }

    /// ZapFast's icon in the menu bar, with its menu (upstream's tray).
    public var menuBarIcon: Bool {
        didSet { defaults.set(menuBarIcon, forKey: Key.menuBarIcon) }
    }

    /// Closing the window leaves ZapFast linked in the background (upstream's
    /// `keep_running_in_background`); off, it quits.
    public var keepRunning: Bool {
        didSet { defaults.set(keepRunning, forKey: Key.keepRunning) }
    }

    /// The chat list shows only the chats' pictures, in a narrow column
    /// (upstream's collapsed sidebar).
    public var compactSidebar: Bool {
        didSet { defaults.set(compactSidebar, forKey: Key.compactSidebar) }
    }

    /// Light, dark, or as macOS is (upstream's theme mode; its default is
    /// dark, a Mac's is to follow the system).
    public var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    /// Archived chats stay archived when a message arrives or is sent
    /// (upstream's `keep_chats_archived`); off, a new message brings the chat
    /// back to the list.
    public internal(set) var keepChatsArchived: Bool {
        didSet { defaults.set(keepChatsArchived, forKey: Key.keepChatsArchived) }
    }

    /// Where new downloads go (upstream's `download_folder`); nil keeps
    /// them in ZapFast's media cache.
    public internal(set) var downloadFolder: String? {
        didSet { defaults.set(downloadFolder, forKey: Key.downloadFolder) }
    }

    /// Proxy for WhatsApp, media and GIF search (upstream's `proxy`), such
    /// as `socks5h://127.0.0.1:9050`; empty follows `ALL_PROXY` or
    /// `HTTPS_PROXY`.
    public internal(set) var proxy: String {
        didSet { defaults.set(proxy, forKey: Key.proxy) }
    }

    /// Return sends; off, Return starts a new line and ⌘Return sends.
    public var enterSends: Bool {
        didSet { defaults.set(enterSends, forKey: Key.enterSends) }
    }

    /// A message's menu offers the quick reactions, floating above it as in
    /// Telegram; off, the menu has none at all.
    public var menuReactions: Bool {
        didSet { defaults.set(menuReactions, forKey: Key.menuReactions) }
    }

    /// The sound a message we send makes as it leaves, as in Telegram.
    public var sendSound: SendSoundStyle {
        didSet { defaults.set(sendSound.rawValue, forKey: Key.sendSoundStyle) }
    }

    /// Voice messages show who recorded them, as on the phone.
    public var voiceAvatars: Bool {
        didSet { defaults.set(voiceAvatars, forKey: Key.voiceAvatars) }
    }

    /// In a group, the number of someone not saved shows beside their name,
    /// over their messages and in quotes of them, as on the phone.
    public var senderPhones: Bool {
        didSet { defaults.set(senderPhones, forKey: Key.senderPhones) }
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

    /// How large photos and videos go out; the media editor's choice is
    /// kept for the next time, as WhatsApp keeps it.
    public var mediaQuality: MediaQuality {
        didSet { defaults.set(mediaQuality.rawValue, forKey: Key.mediaQuality) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.voiceSpeed: Float(1),
            Key.notificationPreviews: true,
            Key.appLockAfter: AutoLock.fifteenMinutes.rawValue,
            Key.messageSound: NotificationSoundInfo.receive.storageValue,
            Key.mentionSound: NotificationSoundInfo.alert.storageValue,
            Key.groupSounds: true,
            Key.voiceAvatars: true,
            Key.senderPhones: true,
            Key.enterSends: true,
            Key.menuReactions: true,
            Key.menuBarIcon: true,
            Key.textScale: 1.0,
            Key.keepRunning: true,
            Key.keepChatsArchived: true,
            Key.unlockWithTouchID: true,
        ])
        voiceSpeed = defaults.float(forKey: Key.voiceSpeed)
        notificationPreviews = defaults.bool(forKey: Key.notificationPreviews)
        giphyKey = defaults.string(forKey: Key.giphyKey) ?? ""
        messageSound = defaults.string(forKey: Key.messageSound).flatMap(NotificationSoundInfo.init(storage:)) ?? .receive
        mentionSound = defaults.string(forKey: Key.mentionSound).flatMap(NotificationSoundInfo.init(storage:)) ?? .alert
        groupSounds = defaults.bool(forKey: Key.groupSounds)
        voiceAvatars = defaults.bool(forKey: Key.voiceAvatars)
        senderPhones = defaults.bool(forKey: Key.senderPhones)
        recentEmoji = defaults.stringArray(forKey: Key.recentEmoji) ?? []
        enterSends = defaults.bool(forKey: Key.enterSends)
        menuReactions = defaults.bool(forKey: Key.menuReactions)
        // The first builds kept an on/off switch; off stays silent.
        let wasOff = defaults.object(forKey: Key.sendSound) as? Bool == false
        sendSound = defaults.string(forKey: Key.sendSoundStyle).flatMap(SendSoundStyle.init(rawValue:))
            ?? (wasOff ? .none : .breath)
        downloadFolder = defaults.string(forKey: Key.downloadFolder)
        menuBarIcon = defaults.bool(forKey: Key.menuBarIcon)
        textScale = defaults.double(forKey: Key.textScale)
        keepRunning = defaults.bool(forKey: Key.keepRunning)
        keepChatsArchived = defaults.bool(forKey: Key.keepChatsArchived)
        compactSidebar = defaults.bool(forKey: Key.compactSidebar)
        appearance = defaults.string(forKey: Key.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .system
        proxy = defaults.string(forKey: Key.proxy) ?? ""
        reactionEmoji = defaults.data(forKey: Key.reactionEmoji)
            .flatMap { try? JSONDecoder().decode([ReactionUse].self, from: $0) } ?? []
        appLockVerifier = defaults.string(forKey: Key.appLockVerifier)
        appLockAfter = AutoLock(rawValue: defaults.integer(forKey: Key.appLockAfter)) ?? .fifteenMinutes
        unlockWithTouchID = defaults.bool(forKey: Key.unlockWithTouchID)
        chatLockVerifier = defaults.string(forKey: Key.chatLockVerifier)
        mediaQuality = defaults.string(forKey: Key.mediaQuality).flatMap(MediaQuality.init(rawValue:)) ?? .standard
    }

    private enum Key {
        static let voiceSpeed = "voiceSpeed"
        static let notificationPreviews = "notificationPreviews"
        static let giphyKey = "giphyKey"
        static let messageSound = "messageSound"
        static let mentionSound = "mentionSound"
        static let groupSounds = "groupSounds"
        static let voiceAvatars = "voiceAvatars"
        static let senderPhones = "senderPhones"
        static let recentEmoji = "recentEmoji"
        static let enterSends = "enterSends"
        static let sendSound = "sendSound"
        static let menuReactions = "menuReactions"
        static let sendSoundStyle = "sendSoundStyle"
        static let downloadFolder = "downloadFolder"
        static let menuBarIcon = "menuBarIcon"
        static let textScale = "textScale"
        static let keepRunning = "keepRunning"
        static let keepChatsArchived = "keepChatsArchived"
        static let appearance = "appearance"
        static let compactSidebar = "compactSidebar"
        static let proxy = "proxy"
        static let reactionEmoji = "reactionEmoji"
        static let appLockVerifier = "appLockVerifier"
        static let appLockAfter = "appLockAfter"
        static let unlockWithTouchID = "unlockWithTouchID"
        static let chatLockVerifier = "chatLockVerifier"
        static let mediaQuality = "mediaQuality"
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

/// The app's appearance, whatever macOS's is.
public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: String { rawValue }
}
