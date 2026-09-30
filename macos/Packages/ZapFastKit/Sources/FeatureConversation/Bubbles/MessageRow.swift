import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// One message in the timeline: the bubble on its side, reactions under it,
/// and the message's context menu.
struct MessageRow: View {
    let message: MessageRecord
    let startsRun: Bool
    let chat: ChatSummary?
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var reacting = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.fromMe { Spacer(minLength: 72) }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: -Metrics.xs) {
                MessageBubble(
                    message: message,
                    senderName: senderName,
                    model: model
                )
                .contextMenu { MessageActions(message: message, model: model) }
                .overlay(alignment: message.fromMe ? .leading : .trailing) {
                    if isLive, hovering || reacting {
                        HoverActions(message: message, model: model, reacting: $reacting)
                            // Beside the bubble, on the side away from its edge.
                            .alignmentGuide(message.fromMe ? .leading : .trailing) { size in
                                message.fromMe ? size[.trailing] + Metrics.s : size[.leading] - Metrics.s
                            }
                            .transition(.opacity)
                    }
                }

                if !message.reactions.isEmpty {
                    ReactionPills(reactions: message.reactions, fromMe: message.fromMe)
                        .padding(.horizontal, Metrics.s)
                }
            }
            .frame(maxWidth: Metrics.bubbleMaxWidth, alignment: message.fromMe ? .trailing : .leading)
            if !message.fromMe { Spacer(minLength: 72) }
        }
        .padding(.horizontal, Metrics.l)
        .padding(.top, startsRun ? Metrics.s : Metrics.xxs)
        .padding(.bottom, Metrics.xxs)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        // A reused cell shows another message.
        .onChange(of: message.id) {
            hovering = false
            reacting = false
        }
        .accessibilityAction(named: Text("Reply")) { if isLive { model.reply(to: message) } }
        .background {
            // A search hit or quote just jumped to, marked for a moment.
            if isHighlighted {
                Rectangle().fill(.tint.opacity(0.18)).transition(.opacity)
            }
        }
        .animation(.zf(reduceMotion, duration: 0.6), value: isHighlighted)
    }

    private var isLive: Bool {
        if case .revoked = message.content { false } else { true }
    }

    private var isHighlighted: Bool {
        model.highlighted == MessageKey(chat: message.chat, message: message.id)
    }

    /// Shown on the first message of a run in a group.
    private var senderName: String? {
        guard startsRun, !message.fromMe, chat?.kind == .group else { return nil }
        return model.chats.personName(message.sender, hint: message.senderName)
    }
}

/// Reactions grouped by emoji, with a count when more than one person chose it.
private struct ReactionPills: View {
    let reactions: [ReactionInfo]
    let fromMe: Bool

    var body: some View {
        let groups = Dictionary(grouping: reactions, by: \.emoji)
            .map { (emoji: $0.key, count: $0.value.count, mine: $0.value.contains(where: \.fromMe)) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.emoji < $1.emoji }
        HStack(spacing: Metrics.xxs) {
            ForEach(groups, id: \.emoji) { group in
                HStack(spacing: 2) {
                    Text(group.emoji)
                    if group.count > 1 {
                        Text("\(group.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.background, in: Capsule())
                .overlay(Capsule().strokeBorder(group.mine ? Color.accentColor : Color(nsColor: .separatorColor)))
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// React and Reply beside the message under the pointer, as upstream's
/// hover controls; everything else stays in the context menu.
private struct HoverActions: View {
    let message: MessageRecord
    let model: AppModel
    @Binding var reacting: Bool

    var body: some View {
        HStack(spacing: 0) {
            button("React", systemImage: "face.smiling") { reacting = true }
                .popover(isPresented: $reacting, arrowEdge: .top) {
                    QuickReactions(mine: message.reactions.first(where: \.fromMe)?.emoji) { emoji in
                        reacting = false
                        model.react(emoji, to: message)
                    }
                }
            button("Reply", systemImage: "arrowshape.turn.up.left") { model.reply(to: message) }
        }
        .padding(.horizontal, Metrics.xxs)
        .modifier(FloatingSurface(Capsule()))
        .accessibilityHidden(true)
    }

    private func button(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
    }
}

/// The quick reactions in a row; the one already chosen is marked, and
/// choosing it again takes it back.
struct QuickReactions: View {
    static let emoji = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    let mine: String?
    let choose: (String) -> Void

    var body: some View {
        HStack(spacing: Metrics.xxs) {
            ForEach(Self.emoji, id: \.self) { emoji in
                Button { choose(emoji == mine ? "" : emoji) } label: {
                    Text(emoji)
                        .font(.system(size: 24))
                        .frame(width: 36, height: 36)
                        .background {
                            if emoji == mine { Circle().fill(.tint.opacity(0.25)) }
                        }
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help(emoji == mine ? Text("Remove \(emoji)") : Text(verbatim: emoji))
            }
        }
        .padding(Metrics.s)
    }
}
