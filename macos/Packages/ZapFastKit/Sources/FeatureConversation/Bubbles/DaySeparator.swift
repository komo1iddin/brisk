import SwiftUI
import ZapFastDesign

/// "Today", "Yesterday", or a date, centred between days.
struct DaySeparator: View {
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
            .accessibilityAddTraits(.isHeader)
    }
}
