import SwiftUI

/// Colours that the system does not already name. Each lives in the asset
/// catalogue with its dark variant; everything else uses semantic system
/// colours (`.primary`, `.secondary`, `Color.accentColor`, materials).
public enum Palette {
    public static let bubbleIncoming = Color("BubbleIncoming", bundle: .module)
    public static let bubbleOutgoingText = Color("BubbleOutgoingText", bundle: .module)
    public static let quoteBar = Color("QuoteBar", bundle: .module)
    public static let dayChip = Color("DayChip", bundle: .module)

    /// Outgoing bubbles follow the accent colour the person chose.
    public static var bubbleOutgoing: Color { .accentColor }

    /// Stable per-sender colours for names in group chats.
    public static func sender(_ id: String) -> Color {
        let colors: [Color] = [.orange, .pink, .purple, .teal, .indigo, .green, .brown, .cyan, .red, .mint]
        var hash: UInt64 = 5381
        for byte in id.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return colors[Int(hash % UInt64(colors.count))]
    }
}

extension Color {
    /// A colour from `#rrggbb` data, such as a label's; grey when unreadable.
    public init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}

/// A small filled circle of a data colour, as an image menus keep in
/// colour (they draw symbols as monochrome templates).
public enum ColorSwatch {
    public static func image(hex: String, diameter: CGFloat = 12) -> Image {
        Image(nsImage: nsImage(hex: hex, diameter: diameter))
    }

    public static func nsImage(hex: String, diameter: CGFloat = 12) -> NSImage {
        let color = NSColor(Color(hex: hex))
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Upstream's names for its preset label colours.
    public static func name(hex: String) -> String {
        switch hex.lowercased() {
        case "#3b82f6": String(localized: "Blue")
        case "#22c55e": String(localized: "Green")
        case "#eab308": String(localized: "Yellow")
        case "#f97316": String(localized: "Orange")
        case "#ef4444": String(localized: "Red")
        case "#ec4899": String(localized: "Pink")
        case "#a855f7": String(localized: "Purple")
        case "#14b8a6": String(localized: "Teal")
        case "#64748b": String(localized: "Grey")
        case "#0ea5e9": String(localized: "Sky blue")
        default: String(localized: "Colour")
        }
    }
}
