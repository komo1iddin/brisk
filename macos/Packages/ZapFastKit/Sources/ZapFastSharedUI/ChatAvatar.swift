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

    public init(chat: ChatSummary, model: AppModel, size: CGFloat) {
        self.chat = chat
        self.model = model
        self.size = size
    }

    public var body: some View {
        AvatarView(
            url: model.avatars.url(for: chat.id),
            seed: chat.id,
            placeholder: placeholder,
            size: size,
            version: model.avatars.version(for: chat.id)
        )
    }

    private var placeholder: AvatarView.Placeholder {
        switch chat.kind {
        case .group: .symbol("person.2.fill")
        case .broadcast: .symbol("megaphone.fill")
        case .direct: .initials(model.chats.title(for: chat))
        }
    }
}
