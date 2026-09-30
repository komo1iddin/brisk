import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

extension ChatTheme {
    /// Resolves a stored look into colours: text and ticks chosen for
    /// contrast with the bubble, WhatsApp's incoming and chip colours over
    /// a wallpaper, upstream's doodle ink for the wallpaper colour.
    public init(_ appearance: ChatAppearance, photos: ThemeStore) {
        let bubble = appearance.bubble
        let plain = appearance.wallpaper == .none
        let text = { (fill: String) in HexColor.text(on: fill) }
        // WhatsApp's blue ticks, unless they would vanish into the bubble.
        let ticks = { (fill: String) in HexColor.contrast(fill, "#53bdeb") >= 1.8 ? "#53bdeb" : text(fill) }
        // A pale bubble cannot tint links and controls; WhatsApp's green can.
        let accent = { (fill: String, fallback: String) in
            HexColor.contrast(fill, "#ffffff") >= 2.5 && HexColor.contrast(fill, "#111b21") >= 2.5 ? fill
                : HexColor.luminance(fill) > 0.4 ? fallback : fill
        }
        let key = (try? JSONEncoder().encode(appearance)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        self.init(
            key: key,
            outgoing: .dynamic(light: bubble.light, dark: bubble.dark),
            outgoingText: .dynamic(light: text(bubble.light), dark: text(bubble.dark)),
            readTicks: .dynamic(light: ticks(bubble.light), dark: ticks(bubble.dark)),
            incoming: plain ? Palette.bubbleIncoming : .dynamic(light: "#ffffff", dark: "#202c33"),
            accent: .dynamic(light: accent(bubble.light, "#008069"), dark: accent(bubble.dark, "#00a884")),
            chip: plain ? Palette.dayChip : .dynamic(light: "#ffffff", dark: "#182229"),
            wallpaper: Self.fill(appearance.wallpaper, photos: photos)
        )
    }

    private static func fill(_ wallpaper: WallpaperStyle, photos: ThemeStore) -> WallpaperFill {
        switch wallpaper {
        case .none:
            return .none
        case let .color(color, doodles):
            let ink: Color? = doodles
                ? .dynamic(light: doodleInk(backgroundHex: color.light), dark: doodleInk(backgroundHex: color.dark))
                : nil
            return .color(.dynamic(light: color.light, dark: color.dark), ink: ink)
        case .gradient(let id):
            guard let preset = ThemePresets.gradient(id) else { return .none }
            return .gradient(zip(preset.light, preset.dark).map { Color.dynamic(light: $0, dark: $1) })
        case let .photo(name, dim):
            return .photo(photos.photoURL(name), dim: dim)
        }
    }
}

extension AppModel {
    /// The theme a chat is drawn with: its own, else the default.
    public func chatTheme(for chat: String?) -> ChatTheme {
        ChatTheme(themes.appearance(for: chat), photos: themes)
    }
}
