import Foundation

/// A colour for light and for dark appearance, `#rrggbb` each.
public struct ThemeColor: Codable, Hashable, Sendable {
    public var light: String
    public var dark: String

    public init(light: String, dark: String) {
        self.light = light
        self.dark = dark
    }

    public init(_ both: String) {
        self.init(light: both, dark: both)
    }
}

/// What is drawn behind a chat's messages.
public enum WallpaperStyle: Codable, Hashable, Sendable {
    /// The window's own background.
    case none
    /// A colour for each appearance, with upstream's doodles over it or not.
    case color(ThemeColor, doodles: Bool)
    /// One of the preset gradients, by id.
    case gradient(String)
    /// A picture of the person's, by file name in the wallpapers folder,
    /// dimmed by `dim` (0…0.8) in dark appearance.
    case photo(String, dim: Double)
}

/// How a chat looks here: our bubbles' colour and the wallpaper. Kept on
/// this Mac only, as WhatsApp keeps chat themes on each device.
public struct ChatAppearance: Codable, Hashable, Sendable {
    public var bubble: ThemeColor
    public var wallpaper: WallpaperStyle

    public init(bubble: ThemeColor, wallpaper: WallpaperStyle) {
        self.bubble = bubble
        self.wallpaper = wallpaper
    }
}

/// A named preset: bubble and wallpaper together.
public struct ThemePreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let appearance: ChatAppearance
}

/// A soft four-corner gradient for each appearance.
public struct GradientPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// Top-left, top-right, bottom-left, bottom-right.
    public let light: [String]
    public let dark: [String]
}

public enum ThemePresets {
    /// WhatsApp's own wallpaper colours, from upstream.
    public static let whatsAppWallpaper = ThemeColor(light: "#efeae2", dark: "#0b141a")
    public static let whatsAppGreen = ThemeColor(light: "#d9fdd3", dark: "#005c4b")

    public static let gradients: [GradientPreset] = [
        GradientPreset(id: "iris", name: String(localized: "Iris"),
                       light: ["#e9d8ff", "#c7b8ff", "#f6c8f0", "#b9c8ff"],
                       dark: ["#2a1f4a", "#1d1838", "#3b1f44", "#1b2448"]),
        GradientPreset(id: "blossom", name: String(localized: "Blossom"),
                       light: ["#ffd6e0", "#ffc2cf", "#ffe4d6", "#f7b3d2"],
                       dark: ["#3d1826", "#2e1320", "#3f2319", "#35162c"]),
        GradientPreset(id: "apricot", name: String(localized: "Apricot"),
                       light: ["#ffe0b8", "#ffc98f", "#ffd9a8", "#ffb27a"],
                       dark: ["#3b2614", "#33200f", "#3f2a16", "#2d1a0c"]),
        GradientPreset(id: "lagoon", name: String(localized: "Lagoon"),
                       light: ["#9fd8f2", "#bfe7f7", "#f5c1d4", "#f7d6c9"],
                       dark: ["#0f2a36", "#12313d", "#361c28", "#2f2320"]),
        GradientPreset(id: "sky", name: String(localized: "Sky"),
                       light: ["#d8eeff", "#b9dcfb", "#e8f4ff", "#a8d0f5"],
                       dark: ["#0f1d2e", "#122a42", "#0c1826", "#15314d"]),
        GradientPreset(id: "meadow", name: String(localized: "Meadow"),
                       light: ["#dff5d8", "#c3ebc0", "#eef7d9", "#b5e2c4"],
                       dark: ["#132a1c", "#0f2418", "#1c2a16", "#0d2a22"]),
    ]

    /// Colours for our bubbles, WhatsApp's green first.
    public static let bubbles: [ThemeColor] = [
        whatsAppGreen,
        ThemeColor(light: "#0a84ff", dark: "#0a84ff"),
        ThemeColor(light: "#5e4ae3", dark: "#6a5cf0"),
        ThemeColor(light: "#b855d6", dark: "#a347c4"),
        ThemeColor(light: "#e0457b", dark: "#c93a6b"),
        ThemeColor(light: "#e2654a", dark: "#c9573e"),
        ThemeColor(light: "#f2a33a", dark: "#b8741f"),
        ThemeColor(light: "#0e7c6b", dark: "#0e6b5c"),
        ThemeColor(light: "#00a884", dark: "#008069"),
        ThemeColor(light: "#3a3a3c", dark: "#48484a"),
    ]

    /// The look WhatsApp opens with: its doodles on its beige, green bubbles.
    public static let classic = ChatAppearance(
        bubble: whatsAppGreen, wallpaper: .color(whatsAppWallpaper, doodles: true)
    )

    public static let all: [ThemePreset] = [
        ThemePreset(id: "classic", name: String(localized: "Classic"), appearance: classic),
        ThemePreset(id: "doodle-blue", name: String(localized: "Doodles"), appearance: ChatAppearance(
            bubble: bubbles[1], wallpaper: .color(ThemeColor(light: "#ffffff", dark: "#111b21"), doodles: true)
        )),
        ThemePreset(id: "plain-blue", name: String(localized: "Plain"), appearance: ChatAppearance(
            bubble: bubbles[1], wallpaper: .none
        )),
        ThemePreset(id: "graphite", name: String(localized: "Graphite"), appearance: ChatAppearance(
            bubble: bubbles[9], wallpaper: .none
        )),
        ThemePreset(id: "iris", name: String(localized: "Iris"), appearance: ChatAppearance(
            bubble: bubbles[2], wallpaper: .gradient("iris")
        )),
        ThemePreset(id: "blossom", name: String(localized: "Blossom"), appearance: ChatAppearance(
            bubble: bubbles[3], wallpaper: .gradient("blossom")
        )),
        ThemePreset(id: "apricot", name: String(localized: "Apricot"), appearance: ChatAppearance(
            bubble: bubbles[5], wallpaper: .gradient("apricot")
        )),
        ThemePreset(id: "lagoon", name: String(localized: "Lagoon"), appearance: ChatAppearance(
            bubble: bubbles[7], wallpaper: .gradient("lagoon")
        )),
        ThemePreset(id: "sky", name: String(localized: "Sky"), appearance: ChatAppearance(
            bubble: bubbles[1], wallpaper: .gradient("sky")
        )),
        ThemePreset(id: "meadow", name: String(localized: "Meadow"), appearance: ChatAppearance(
            bubble: bubbles[8], wallpaper: .gradient("meadow")
        )),
    ]

    public static func gradient(_ id: String) -> GradientPreset? {
        gradients.first { $0.id == id }
    }
}
