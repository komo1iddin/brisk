import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// A message matching the sidebar search: its chat, when it was sent, and
/// the text around the match. Clicking it opens the chat at the message.
struct MessageHitRow: View {
    let message: MessageRecord
    let query: String
    let model: AppModel

    var body: some View {
        let chat = model.chats.chat(message.chat)
        Button { model.open(message) } label: {
            HStack(spacing: Metrics.m) {
                if let chat {
                    ChatAvatar(chat: chat, model: model, size: Metrics.rowAvatar)
                } else {
                    AvatarView(
                        url: nil,
                        seed: message.chat,
                        placeholder: .initials(model.chats.displayName(message.chat)),
                        size: Metrics.rowAvatar
                    )
                }
                VStack(alignment: .leading, spacing: Metrics.xxs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(chat.map(model.chats.title(for:)) ?? model.chats.displayName(message.chat))
                            .lineLimit(1)
                        Spacer(minLength: Metrics.xs)
                        Text(DateText.chatRow(message.timestamp))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(snippet(in: chat))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, Metrics.xs)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// "Name: text" in a group or for our own messages, as in the chat list.
    private func snippet(in chat: ChatSummary?) -> AttributedString {
        let text = SearchSnippet.make(model.messageText(message), matching: query)
        let sender: String? = if message.fromMe {
            String(localized: "You")
        } else if chat?.kind == .group {
            model.chats.personName(message.sender, hint: message.senderName)
        } else {
            nil
        }
        guard let sender else { return text }
        return AttributedString("\(sender): ") + text
    }
}
