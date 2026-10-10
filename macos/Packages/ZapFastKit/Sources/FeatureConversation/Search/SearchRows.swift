import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// One match: who wrote it and when, and the text around the words found.
struct HitRow: View {
    let message: MessageRecord
    let query: String
    let model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.s) {
            SenderAvatar(sender: message.fromMe ? .me : .person(message.sender), name: sender, model: model, size: 30)
            VStack(alignment: .leading, spacing: Metrics.xxs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(sender)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: Metrics.xs)
                    Text(DateText.chatRow(message.timestamp))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(SearchSnippet.make(model.messageText(message), matching: query))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var sender: String {
        message.fromMe ? searchText("search.you") : model.chats.displayName(message.sender, hint: message.senderName)
    }
}

/// A row of a search list: lit under the pointer, and marked, as a menu's
/// item is, with rounded corners inset from the list's edges.
struct SearchRowStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SearchRowBody(label: configuration.label, selected: selected, pressed: configuration.isPressed)
    }
}

/// A view of its own, since a style keeps no state.
private struct SearchRowBody<Label: View>: View {
    let label: Label
    let selected: Bool
    let pressed: Bool
    @State private var hovering = false

    var body: some View {
        label
            .padding(.horizontal, Metrics.s)
            .padding(.vertical, Metrics.xs + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovering = $0 }
    }

    private var fill: AnyShapeStyle {
        if selected { return AnyShapeStyle(.tint.opacity(0.18)) }
        if pressed { return AnyShapeStyle(.primary.opacity(0.1)) }
        if hovering { return AnyShapeStyle(.primary.opacity(0.05)) }
        return AnyShapeStyle(.clear)
    }
}
