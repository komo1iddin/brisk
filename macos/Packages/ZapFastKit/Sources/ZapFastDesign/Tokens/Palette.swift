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
