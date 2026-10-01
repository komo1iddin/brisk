import AppKit

/// `Palette` for views drawn with AppKit and Core Animation, such as the
/// message timeline's cells. The colours are dynamic: they resolve for the
/// appearance they are drawn in.
public nonisolated enum AppKitPalette {
    public static let bubbleIncoming = named("BubbleIncoming")
    public static let bubbleOutgoingText = named("BubbleOutgoingText")
    public static let dayChip = named("DayChip")
    /// What sits inside a bubble on its own ground (a quote, a file's or a
    /// link's card), as WhatsApp shades it: a touch darker than the bubble,
    /// whatever its colour.
    public static let inset = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0, alpha: 0.18)
            : NSColor(white: 0, alpha: 0.045)
    }

    /// Outgoing bubbles follow the accent colour the person chose.
    public static var bubbleOutgoing: NSColor { .controlAccentColor }

    /// Names in group chats, as WhatsApp colours them: deep enough to read
    /// on a light bubble, lighter in the dark. Which one a person gets is
    /// `NameColors`'s.
    public static let nameColorCount = names.count

    public static func name(_ index: Int) -> NSColor {
        names[((index % names.count) + names.count) % names.count]
    }

    private static let names: [NSColor] = [
        (0x408458, 0x6BC489), (0xC02838, 0xF36D7C), (0x1F6FD1, 0x6AA8F5), (0x8E44AD, 0xC590E0),
        (0xC95100, 0xF59A57), (0x00838F, 0x4DD0DA), (0xC2185B, 0xF06A9B), (0x3F51B5, 0x8F9BEB),
        (0xA86F12, 0xE8B04F), (0x6F7F14, 0xB9CB55), (0xA0329F, 0xE07ADF), (0x0277BD, 0x5BB8EE),
        (0xB5482E, 0xEC8A70), (0x2E8B6E, 0x5ECFA8), (0x6A4CC6, 0xA891F2), (0xB03A5B, 0xE8829E),
    ].map { light, dark in
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1
            )
        }
    }

    /// `Palette.sender(_:)` in AppKit colours: the same hash, the same order.
    public static func sender(_ id: String) -> NSColor {
        let colors: [NSColor] = [
            .systemOrange, .systemPink, .systemPurple, .systemTeal, .systemIndigo,
            .systemGreen, .systemBrown, .systemCyan, .systemRed, .systemMint,
        ]
        var hash: UInt64 = 5381
        for byte in id.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return colors[Int(hash % UInt64(colors.count))]
    }

    private static func named(_ name: String) -> NSColor {
        NSColor(named: name, bundle: .module) ?? .labelColor
    }
}
