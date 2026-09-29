import SwiftUI
import ZapFastDesign

/// "Today", "Yesterday", or a date, centred between days.
struct DaySeparator: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Metrics.m)
            .padding(.vertical, Metrics.xs)
            .background(Palette.dayChip, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metrics.s)
            .accessibilityAddTraits(.isHeader)
    }
}
