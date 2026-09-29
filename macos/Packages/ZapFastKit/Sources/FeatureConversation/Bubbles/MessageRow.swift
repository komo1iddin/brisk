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
