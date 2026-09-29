import AVFoundation
import Foundation
import UserNotifications
import ZapFastBridge

extension NotificationSoundInfo {
    /// How Preferences keep it.
    var storageValue: String {
        switch self {
        case .receive: "receive"
        case .alert: "alert"
        case .system: "system"
        case .none: "none"
        case .custom(let path): "custom:\(path)"
        }
    }

    init?(storage: String) {
        switch storage {
        case "receive": self = .receive
        case "alert": self = .alert
        case "system": self = .system
        case "none": self = .none
        default:
            guard storage.hasPrefix("custom:") else { return nil }
            self = .custom(path: String(storage.dropFirst("custom:".count)))
        }
    }

    /// Upstream's two bundled sounds, copied into the app.
    var bundledFile: String? {
        switch self {
        case .receive: "receive.wav"
        case .alert: "alert.wav"
        default: nil
        }
    }
}

/// Upstream's `notification_sound`: the chat's own sound, else the mention
/// sound for a message addressed to us, else silence for a group while
/// group sounds are off, else the message sound.
func notificationSound(
    chat: NotificationSoundInfo?,
    forUs: Bool,
    isGroup: Bool,
    preferences: Preferences
) -> NotificationSoundInfo {
    if let chat { return chat }
    if forUs { return preferences.mentionSound }
    if isGroup, !preferences.groupSounds { return .none }
    return preferences.messageSound
}

/// Plays a sound Notification Center cannot (a file of the person's), and
/// previews sounds in Settings.
public final class SoundPlayer {
    public static let shared = SoundPlayer()
    private var player: AVAudioPlayer?

    /// The notification's own sound, or nil when this plays it instead.
    func notificationSound(for sound: NotificationSoundInfo) -> UNNotificationSound? {
        switch sound {
        case .system: return .default
        case .none: return nil
        case .receive, .alert: return sound.bundledFile.map { UNNotificationSound(named: UNNotificationSoundName($0)) }
        case .custom(let path):
            play(URL(filePath: path))
            return nil
        }
    }

    /// Plays a sound now, as a preview; the system's is not known here.
    public func preview(_ sound: NotificationSoundInfo) {
        switch sound {
        case .receive, .alert:
            let name = sound.bundledFile.map { ($0 as NSString).deletingPathExtension }
            if let url = name.flatMap({ Bundle.main.url(forResource: $0, withExtension: "wav") }) { play(url) }
        case .custom(let path):
            play(URL(filePath: path))
        case .system, .none:
            break
        }
    }

    private func play(_ url: URL) {
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
}
