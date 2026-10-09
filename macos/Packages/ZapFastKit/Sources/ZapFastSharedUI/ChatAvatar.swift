import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// A chat's avatar: its profile picture once fetched, else initials for a
/// person or a symbol for a group or channel.
public struct ChatAvatar: View {
    private let chat: ChatSummary
    private let model: AppModel
    private let size: CGFloat
    /// The chat's name when the caller has it: read here, it is read from
    /// stores that change with every message.
    private let title: String?

    public init(chat: ChatSummary, model: AppModel, size: CGFloat, title: String? = nil) {
        self.chat = chat
        self.model = model
        self.size = size
        self.title = title
    }

    public var body: some View {
        AvatarView(
            url: model.avatars.url(for: chat.id),
            seed: chat.id,
            placeholder: placeholder,
            size: size,
            version: model.avatars.version(for: chat.id)
        )
        .overlay(alignment: .bottomTrailing) {
            // Disappearing messages are on, as upstream's timer badge says.
            if (chat.ephemeralExpiration ?? 0) > 0 {
                DisappearingBadge(size: min(max(size * 0.38, 13), 18))
                    .offset(x: size * 0.06, y: size * 0.06)
            }
        }
    }

    private var placeholder: AvatarView.Placeholder {
        switch chat.kind {
        case .group: .symbol("person.2.fill")
        case .broadcast: .symbol("megaphone.fill")
        case .direct: .initials(title ?? model.chats.title(for: chat))
        }
    }
}

/// The timer on the avatar of a chat whose messages disappear.
public struct DisappearingBadge: View {
    let size: CGFloat

    public init(size: CGFloat) {
        self.size = size
    }

    public var body: some View {
        Image(systemName: "timer")
            .font(.system(size: size * 0.62, weight: .bold))
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
            .background(Circle().fill(.background))
            .accessibilityLabel(Text("Disappearing messages"))
    }
}
