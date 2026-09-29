import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZapFastBridge
import ZapFastCore

/// Names and pickers for notification sounds, shared by Settings and the
/// chat menu.
public enum SoundChoice {
    /// The sounds offered by name; a file of the person's is the fifth.
    public static let named: [NotificationSoundInfo] = [.receive, .alert, .system, .none]

    public static func title(_ sound: NotificationSoundInfo) -> String {
        switch sound {
        case .receive: String(localized: "ZapFast")
        case .alert: String(localized: "Alert")
        case .system: String(localized: "System Default")
        case .none: String(localized: "None")
        case .custom(let path): URL(filePath: path).deletingPathExtension().lastPathComponent
        }
    }

    /// Asks for an audio file; nil when cancelled.
    public static func chooseFile() -> NotificationSoundInfo? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a sound for notifications")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return .custom(path: url.path(percentEncoded: false))
    }
}

/// A chat's own sound, in its menu: Settings' sound, a named one, or a file.
public struct ChatSoundMenu: View {
    let chat: ChatSummary
    let model: AppModel

    public init(chat: ChatSummary, model: AppModel) {
        self.chat = chat
        self.model = model
    }

    public var body: some View {
        Menu("Notification Sound", systemImage: "speaker.wave.2") {
            Toggle("Default", isOn: Binding(
                get: { chat.notificationSound == nil },
                set: { if $0 { model.setChatSound(nil, chat: chat.id) } }
            ))
            Divider()
            ForEach(SoundChoice.named, id: \.self) { sound in
                Toggle(SoundChoice.title(sound), isOn: Binding(
                    get: { chat.notificationSound == sound },
                    set: { if $0 { model.setChatSound(sound, chat: chat.id) } }
                ))
            }
            if case .custom = chat.notificationSound, let sound = chat.notificationSound {
                Toggle(SoundChoice.title(sound), isOn: .constant(true))
            }
            Divider()
            Button("Choose File…") {
                if let sound = SoundChoice.chooseFile() { model.setChatSound(sound, chat: chat.id) }
            }
        }
    }
}
