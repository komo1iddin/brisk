import SwiftUI
import ZapFastDesign

enum AttachChoice: CaseIterable, Identifiable {
    case document, media, poll, sticker
    var id: Self { self }
}

/// What + offers, as tiles in its popover: each kind of attachment with
/// its own colour, as the phone's attach sheet has, drawn like the
/// system's app icons.
struct AttachPanel: View {
    /// Polls and stickers are new messages, not part of an edit.
    let creates: Bool
    let choose: (AttachChoice) -> Void

    var body: some View {
        HStack(spacing: Metrics.xs) {
            ForEach(AttachChoice.allCases) { choice in
                AttachTile(choice: choice) { choose(choice) }
                    .disabled(!creates && (choice == .poll || choice == .sticker))
            }
        }
        .padding(Metrics.s)
    }
}

private struct AttachTile: View {
    let choice: AttachChoice
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: Metrics.s) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(tint.gradient, in: .circle)
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: tint.opacity(hovered ? 0.45 : 0.25), radius: hovered ? 6 : 3, y: 2)
                    .scaleEffect(hovered && isEnabled ? 1.06 : 1)
                Text(title)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                    .frame(width: 84)
            }
            .padding(.vertical, Metrics.s)
            .padding(.horizontal, Metrics.xxs)
            .background {
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(.primary.opacity(hovered && isEnabled ? 0.06 : 0))
            }
            .contentShape(.rect(cornerRadius: Metrics.cardRadius))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .animation(.snappy(duration: 0.15), value: hovered)
        .accessibilityLabel(title)
    }

    private var title: LocalizedStringKey {
        switch choice {
        case .document: "Document"
        case .media: "Photos and Videos"
        case .poll: "Poll"
        case .sticker: "New Sticker"
        }
    }

    private var symbol: String {
        switch choice {
        case .document: "doc.fill"
        case .media: "photo.on.rectangle.angled"
        case .poll: "chart.bar.fill"
        case .sticker: "face.smiling.inverse"
        }
    }

    private var tint: Color {
        switch choice {
        case .document: .indigo
        case .media: .blue
        case .poll: .orange
        case .sticker: .pink
        }
    }
}
