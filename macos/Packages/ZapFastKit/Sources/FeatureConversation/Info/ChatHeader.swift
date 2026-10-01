import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// The open chat's picture, name and presence at the head of the window,
/// as WhatsApp draws them. A click opens the chat's info over the chat.
struct ChatHeader: View {
    let chat: ChatSummary
    /// The chat's name and a group's members, read by the caller (from
    /// stores that change with every message).
    let title: String
    let members: String
    let model: AppModel
    let request: (InfoRequest) -> Void
    @State private var hovering = false

    var body: some View {
        let subtitle = subtitle
        Button {
            if model.infoChat == chat.id { model.closeInfo() } else { model.showInfo(in: chat.id) }
        } label: {
            HStack(spacing: Metrics.s) {
                ChatAvatar(chat: chat, model: model, size: Metrics.headerAvatar, title: title)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.leading, Metrics.xs)
            .padding(.trailing, Metrics.s)
            .padding(.vertical, Metrics.xxs)
            .frame(maxWidth: 360, alignment: .leading)
            .background(
                hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear),
                in: .rect(cornerRadius: Metrics.controlRadius)
            )
            .contentShape(.rect(cornerRadius: Metrics.controlRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show chat info (⌘I)")
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(subtitle))
        .accessibilityHint(Text("Shows the chat's info"))
        .popover(isPresented: shown, arrowEdge: .bottom) {
            ChatInfoPanel(chatID: chat.id, model: model, request: request)
        }
    }

    private var shown: Binding<Bool> {
        Binding(
            get: { model.infoChat == chat.id },
            set: { if !$0, model.infoChat == chat.id { model.closeInfo() } }
        )
    }

    /// Typing, presence, or group members.
    private var subtitle: String {
        if case let senders = model.conversations.typing(in: chat.id), !senders.isEmpty {
            if chat.kind == .group, let first = senders.first {
                return String(localized: "\(model.chats.personName(first, hint: nil)) is typing…")
            }
            return String(localized: "typing…")
        }
        switch chat.kind {
        case .group:
            return members
        case .broadcast:
            return chat.isChannel ? String(localized: "Channel") : String(localized: "Broadcast list")
        case .direct:
            if let presence = model.conversations.presence(of: chat.id) {
                if presence.online { return String(localized: "online") }
                if let seen = presence.lastSeen { return DateText.lastSeen(seen) }
            }
            return chat.phone ?? ""
        }
    }
}
