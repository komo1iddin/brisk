import AppKit
import SwiftUI
import ZapFastDesign

/// How the open chat is drawn: its theme and the message text size.
struct TimelineStyle: Equatable {
    var theme: ChatTheme
    var textScale: Double

    static let standard = TimelineStyle(theme: .standard, textScale: 1)
}

/// A chat theme's colours in AppKit, for the cells Core Animation draws and
/// the layout measured off the main actor. The colours stay dynamic: they
/// resolve for the appearance they are drawn in. Two values of the same
/// theme and text size are equal.
nonisolated struct BubbleColors: @unchecked Sendable, Equatable {
    let key: String
    let textScale: Double
    let outgoing: NSColor
    let outgoingText: NSColor
    let readTicks: NSColor
    let incoming: NSColor
    let accent: NSColor
    let chip: NSColor
    /// Something is drawn behind the messages, so bubbles lift off it.
    let hasWallpaper: Bool

    @MainActor
    init(_ style: TimelineStyle) {
        let theme = style.theme
        key = theme.key
        textScale = style.textScale
        outgoing = NSColor(theme.outgoing)
        outgoingText = NSColor(theme.outgoingText)
        readTicks = NSColor(theme.readTicks)
        incoming = NSColor(theme.incoming)
        accent = NSColor(theme.accent)
        chip = NSColor(theme.chip)
        hasWallpaper = theme.hasWallpaper
    }

    static func == (lhs: BubbleColors, rhs: BubbleColors) -> Bool {
        lhs.key == rhs.key && lhs.textScale == rhs.textScale
    }
}
