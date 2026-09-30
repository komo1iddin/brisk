import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers
import ZapFastBridge

/// The default chat look and each chat's own, kept in `UserDefaults`;
/// chosen pictures are copied into the app's wallpapers folder, scaled to
/// upstream's largest side.
@Observable
public final class ThemeStore {
    public private(set) var defaultAppearance: ChatAppearance
    public private(set) var chatAppearances: [String: ChatAppearance]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored public let wallpapersFolder: URL

    /// Upstream's `wallpaper::MAX_SIDE`.
    nonisolated static let maximumSide = 2560

    init(defaults: UserDefaults, wallpapersFolder: URL) {
        self.defaults = defaults
        self.wallpapersFolder = wallpapersFolder
        let decoder = JSONDecoder()
        defaultAppearance = defaults.data(forKey: Key.defaultAppearance)
            .flatMap { try? decoder.decode(ChatAppearance.self, from: $0) } ?? ThemePresets.system
        chatAppearances = defaults.data(forKey: Key.chatAppearances)
            .flatMap { try? decoder.decode([String: ChatAppearance].self, from: $0) } ?? [:]
    }

    /// A chat's look: its own, else the default.
    public func appearance(for chat: String?) -> ChatAppearance {
        chat.flatMap { chatAppearances[$0] } ?? defaultAppearance
    }

    public func hasOwnAppearance(_ chat: String) -> Bool {
        chatAppearances[chat] != nil
    }

    /// Sets the default look, or one chat's with `chat`.
    public func set(_ appearance: ChatAppearance, for chat: String?) {
        if let chat {
            chatAppearances[chat] = appearance
        } else {
            defaultAppearance = appearance
        }
        save()
    }

    /// The chat follows the default look again.
    public func useDefault(for chat: String) {
        guard chatAppearances.removeValue(forKey: chat) != nil else { return }
        save()
    }

    /// Where a wallpaper picture's file is.
    public func photoURL(_ name: String) -> URL {
        wallpapersFolder.appending(path: name)
    }

    /// Copies a picture into the wallpapers folder as a JPEG no larger than
    /// upstream's limit, off the main actor; its file name, or nil.
    public func importPhoto(_ url: URL) async -> String? {
        let folder = wallpapersFolder
        return await Self.copyScaled(url, into: folder)
    }

    @concurrent
    private static func copyScaled(_ url: URL, into folder: URL) async -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).jpg"
        let target = folder.appending(path: name)
        guard let destination = CGImageDestinationCreateWithURL(
            target as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? name : nil
    }

    private func save() {
        let encoder = JSONEncoder()
        defaults.set(try? encoder.encode(defaultAppearance), forKey: Key.defaultAppearance)
        defaults.set(try? encoder.encode(chatAppearances), forKey: Key.chatAppearances)
        removeUnusedPhotos()
    }

    /// Pictures no look uses any more.
    private func removeUnusedPhotos() {
        let used = Set(([defaultAppearance] + Array(chatAppearances.values)).compactMap { appearance -> String? in
            if case .photo(let name, _) = appearance.wallpaper { name } else { nil }
        })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: wallpapersFolder.path(percentEncoded: false))) ?? []
        for file in files where !used.contains(file) {
            try? FileManager.default.removeItem(at: wallpapersFolder.appending(path: file))
        }
    }

    private enum Key {
        static let defaultAppearance = "chatThemeDefault"
        static let chatAppearances = "chatThemes"
    }
}

/// WhatsApp's wallpaper colours through upstream, for the colour picker.
public enum WallpaperColors {
    public static func choices(dark: Bool) -> [WallpaperColorInfo] {
        wallpaperColors(dark: dark)
    }
}
