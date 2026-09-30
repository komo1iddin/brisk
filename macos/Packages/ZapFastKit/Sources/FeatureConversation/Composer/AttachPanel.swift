import SwiftUI
import ZapFastDesign

enum AttachChoice: CaseIterable, Identifiable {
    case document, media, poll, sticker
    var id: Self { self }
}

/// What + offers, as tiles in its popover, the way the phone's attach
/// sheet has them: each kind's own coloured symbol on a quiet disc,
/// Liquid Glass on macOS 26.
struct AttachPanel: View {
    /// Polls and stickers are new messages, not part of an edit.
    let creates: Bool
    let choose: (AttachChoice) -> Void

    var body: some View {
        HStack(spacing: Metrics.xxs) {
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
                    .font(.system(size: 24))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(width: 56, height: 56)
                    .modifier(AttachDisc(hovered: hovered && isEnabled))
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                    .frame(width: 80)
            }
            .padding(.vertical, Metrics.xs)
            .contentShape(.rect(cornerRadius: Metrics.cardRadius))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
    }

    private var title: LocalizedStringKey {
        switch choice {
        case .document: "File"
        case .media: "Photos and Videos"
        case .poll: "Poll"
        case .sticker: "New Sticker"
        }
    }

    private var symbol: String {
        switch choice {
        case .document: "folder.fill"
        case .media: "photo.fill.on.rectangle.fill"
        case .poll: "text.alignleft"
        case .sticker: "face.smiling.fill"
        }
    }

    private var tint: Color {
        switch choice {
        case .document: Color(red: 0.23, green: 0.56, blue: 0.93)
        case .media: Color(red: 0.16, green: 0.45, blue: 0.95)
        case .poll: Color(red: 0.96, green: 0.70, blue: 0.19)
        case .sticker: Color(red: 0.07, green: 0.66, blue: 0.56)
        }
    }
}

/// The disc behind a tile's symbol: glass that answers the pointer on
/// macOS 26, a soft fill before it.
private struct AttachDisc: ViewModifier {
    let hovered: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
                .background(.primary.opacity(hovered ? 0.1 : 0.05), in: .circle)
                .animation(.snappy(duration: 0.15), value: hovered)
        }
    }
}
