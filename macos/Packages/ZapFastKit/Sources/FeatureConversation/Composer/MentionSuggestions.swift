import SwiftUI
import ZapFastCore
import ZapFastDesign

/// Group members matching the `@` being typed, above the message field.
/// The keyboard stays in the field: ↑ ↓ move, Return or Tab picks, Escape
/// closes; a click picks too.
struct MentionSuggestions: View {
    let tracker: MentionTracker
    let model: AppModel

    private let rowHeight: CGFloat = 34
    private let visibleRows = 5

    var body: some View {
        let list = tracker.suggestions
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, candidate in
                        row(candidate, selected: index == tracker.selected)
                            .id(candidate.id)
                            .onHover { if $0 { tracker.selected = index } }
                            .onTapGesture { tracker.pick(candidate) }
                            .accessibilityAction { tracker.pick(candidate) }
                    }
                }
                .padding(Metrics.xs)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: rowHeight * CGFloat(min(list.count, visibleRows)) + Metrics.xs * 2)
            .onChange(of: tracker.selected, initial: true) { _, index in
                guard list.indices.contains(index) else { return }
                proxy.scrollTo(list[index].id)
                // The keyboard stays in the field, so VoiceOver hears the choice.
                AccessibilityNotification.Announcement(list[index].name).post()
            }
        }
        .background(.background, in: .rect(cornerRadius: Metrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mention suggestions")
    }

    private func row(_ candidate: MentionCandidate, selected: Bool) -> some View {
        HStack(spacing: Metrics.s) {
            AvatarView(
                url: model.avatars.url(for: candidate.id),
                seed: candidate.id,
                placeholder: .initials(String(candidate.name.trimmingPrefix("~"))),
                size: 24,
                version: model.avatars.version(for: candidate.id)
            )
            Text(candidate.name)
                .lineLimit(1)
            Spacer(minLength: Metrics.s)
            if let phone = candidate.phone, phone != candidate.name {
                Text(phone)
                    .font(.caption)
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
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
