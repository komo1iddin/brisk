import SwiftUI
import ZapFastBridge
import ZapFastDesign

/// Emoji matching the `:shortcode` being typed, above the message field,
/// kept by the keyboard as mention suggestions are.
struct EmojiSuggestions: View {
    let tracker: EmojiTracker

    private let rowHeight: CGFloat = 34

    var body: some View {
        let list = tracker.suggestions
        VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.emoji) { index, suggestion in
                row(suggestion, selected: index == tracker.selected)
                    .onHover { if $0 { tracker.selected = index } }
                    .onTapGesture { tracker.pick(suggestion) }
                    .accessibilityAction { tracker.pick(suggestion) }
            }
        }
        // The keyboard stays in the field, so VoiceOver hears the choice.
        .onChange(of: list.indices.contains(tracker.selected) ? list[tracker.selected].emoji : nil, initial: true) { _, emoji in
            guard let emoji, let chosen = list.first(where: { $0.emoji == emoji }) else { return }
            AccessibilityNotification.Announcement("\(chosen.name), \(chosen.shortcode)").post()
        }
        .padding(Metrics.xs)
        .background(.background, in: .rect(cornerRadius: Metrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Emoji suggestions")
    }

    private func row(_ suggestion: EmojiSuggestionInfo, selected: Bool) -> some View {
        HStack(spacing: Metrics.s) {
            Text(suggestion.emoji)
                .font(.system(size: 20))
                .frame(width: 28)
            Text(suggestion.shortcode)
                .lineLimit(1)
            Text(suggestion.name)
                .font(.caption)
                .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, Metrics.s)
        .frame(height: rowHeight)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: Metrics.controlRadius).fill(Color.accentColor)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
