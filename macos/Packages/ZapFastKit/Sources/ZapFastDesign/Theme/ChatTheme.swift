import AppKit
import SwiftUI

/// The colours and wallpaper a chat is drawn with, resolved for both
/// appearances (each colour follows light and dark by itself).
public struct ChatTheme: Equatable {
    /// Identifies the look it was made from; two themes with the same key
    /// draw the same.
    public let key: String
    public let outgoing: Color
    public let outgoingText: Color
    /// Ticks once read, readable on `outgoing`.
    public let readTicks: Color
    public let incoming: Color
    /// Links, controls and highlights in the chat.
    public let accent: Color
    /// Day separators and other chips over the wallpaper.
    public let chip: Color
    public let wallpaper: WallpaperFill

    public init(
        key: String, outgoing: Color, outgoingText: Color, readTicks: Color, incoming: Color,
        accent: Color, chip: Color, wallpaper: WallpaperFill
    ) {
        self.key = key
        self.outgoing = outgoing
        self.outgoingText = outgoingText
        self.readTicks = readTicks
        self.incoming = incoming
        self.accent = accent
        self.chip = chip
        self.wallpaper = wallpaper
    }

    /// Something is drawn behind the messages, so bubbles lift off it.
    public var hasWallpaper: Bool {
        if case .none = wallpaper { false } else { true }
    }

    public static func == (lhs: ChatTheme, rhs: ChatTheme) -> Bool {
        lhs.key == rhs.key
    }

    /// The system's look, for previews and anything without a theme.
    public static let standard = ChatTheme(
        key: "standard", outgoing: .accentColor, outgoingText: .white, readTicks: .white,
        incoming: Palette.bubbleIncoming, accent: .accentColor, chip: Palette.dayChip, wallpaper: .none
    )
}

/// What is drawn behind the messages.
public enum WallpaperFill {
    case none
    /// A colour, with the doodles in `ink` over it when there is ink.
    case color(Color, ink: Color?)
    /// Four corner colours: top-left, top-right, bottom-left, bottom-right.
    case gradient([Color])
    /// A picture, darkened by `dim` in dark appearance.
    case photo(URL, dim: Double)
}

extension EnvironmentValues {
    @Entry public var chatTheme: ChatTheme = .standard
}

// MARK: - Colour arithmetic

/// Hex colours and the contrast rules the themes use.
public enum HexColor {
    /// sRGB components 0…1, and alpha when the hex carries it.
    public static func components(_ hex: String) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits, radix: 16) ?? 0
        if digits.count == 8 {
            return (Double((value >> 24) & 0xff) / 255, Double((value >> 16) & 0xff) / 255,
                    Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
        }
        return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255,
                Double(value & 0xff) / 255, 1)
    }

    /// WCAG relative luminance.
    public static func luminance(_ hex: String) -> Double {
        let (red, green, blue, _) = components(hex)
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio between two colours, 1…21.
    public static func contrast(_ first: String, _ second: String) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Dark text on light fills, white on the rest, whichever reads better.
    public static func text(on fill: String) -> String {
        contrast(fill, "#111b21") >= contrast(fill, "#ffffff") ? "#111b21" : "#ffffff"
    }

    public static func nsColor(_ hex: String) -> NSColor {
        let (red, green, blue, alpha) = components(hex)
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension Color {
    /// A colour that is `light` in light appearance and `dark` in dark.
    public static func dynamic(light: String, dark: String) -> Color {
        let light = HexColor.nsColor(light), dark = HexColor.nsColor(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
