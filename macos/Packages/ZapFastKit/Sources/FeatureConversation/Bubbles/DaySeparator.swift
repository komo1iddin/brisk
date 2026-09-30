import SwiftUI
import ZapFastDesign

/// "Today", "Yesterday", or a date, centred between days.
struct DaySeparator: View {
    let title: String

    var body: some View {
        TimelineChip(title: title)
            .accessibilityAddTraits(.isHeader)
    }
}

/// "3 unread messages", above the first message that was unread when the
/// chat was opened.
struct UnreadSeparator: View {
    let count: UInt32

    var body: some View {
        TimelineChip(title: String(AttributedString(localized: "^[\(count) unread message](inflect: true)").characters))
    }
}

/// A caption centred in the timeline on the theme's chip colour.
private struct TimelineChip: View {
    let title: String
    @Environment(\.chatTheme) private var theme

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Metrics.m)
            .padding(.vertical, Metrics.xs)
            .background(theme.chip, in: Capsule())
            .shadow(color: .black.opacity(theme.hasWallpaper ? 0.08 : 0), radius: 0.5, y: 0.5)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metrics.s)
    }
}
