import AppKit

/// `Palette` for views drawn with AppKit and Core Animation, such as the
/// message timeline's cells. The colours are dynamic: they resolve for the
/// appearance they are drawn in.
public nonisolated enum AppKitPalette {
    public static let bubbleIncoming = named("BubbleIncoming")
    public static let bubbleOutgoingText = named("BubbleOutgoingText")
    public static let quoteBar = named("QuoteBar")
    public static let dayChip = named("DayChip")

    /// Outgoing bubbles follow the accent colour the person chose.
    public static var bubbleOutgoing: NSColor { .controlAccentColor }

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
