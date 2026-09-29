import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// One chat in the sidebar: avatar, title, time, last message, badges.
struct ChatRow: View {
    let chat: ChatSummary
    let model: AppModel

    var body: some View {
        let title = model.chats.title(for: chat)
        let muted = model.chats.isMuted(chat)
        HStack(spacing: Metrics.m) {
            ChatAvatar(chat: chat, model: model, size: Metrics.rowAvatar)
            VStack(alignment: .leading, spacing: Metrics.xxs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.body.weight(chat.looksUnread ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: Metrics.xs)
                    Text(DateText.chatRow(chat.lastActivity))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(chat.unread > 0 && !muted ? Color.accentColor : Color.secondary)
                }
                HStack(alignment: .center, spacing: Metrics.xs) {
                    preview
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: Metrics.xs)
                    indicators(muted: muted)
                }
            }
        }
        .padding(.vertical, Metrics.xs)
        .help(chat.last?.full ?? "")
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var preview: some View {
        if let typing = typingLine {
            Text(typing).foregroundStyle(.tint)
        } else if let draft = model.chats.drafts[chat.id], !draft.isEmpty, chat.id != model.selectedChatID {
            Text("Draft: ").foregroundStyle(.red) + Text(draft)
        } else if let last = chat.last {
            HStack(spacing: Metrics.xxs) {
                if last.fromMe {
                    DeliveryTicks(DeliveryTicks.State(last.status))
                }
                Text(senderPrefix(last) + last.summary)
            }
        } else {
            Text(" ")
        }
    }

    private var typingLine: String? {
        guard let senders = model.conversations.typing[chat.id], !senders.isEmpty else { return nil }
        if chat.kind == .group, let first = senders.first {
            return String(localized: "\(model.chats.personName(first, hint: nil)) is typing…")
        }
        return String(localized: "typing…")
    }

    private func senderPrefix(_ last: ChatPreview) -> String {
        guard chat.kind == .group, !last.fromMe else { return "" }
        let name = model.chats.personName(last.sender, hint: last.senderName)
        return "\(name): "
    }

    @ViewBuilder private func indicators(muted: Bool) -> some View {
        if muted {
            Image(systemName: "bell.slash.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Muted")
        }
        if chat.pinned {
            Image(systemName: "pin.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Pinned")
        }
        if chat.looksUnread {
            UnreadBadge(count: chat.unread, muted: muted)
        }
    }
}

