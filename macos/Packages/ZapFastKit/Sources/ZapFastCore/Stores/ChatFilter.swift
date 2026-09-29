import ZapFastBridge

/// The chat list's filter chips. Same rules as upstream's `ChatFilter`.
public enum ChatFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case unread
    /// One-to-one chats: neither groups nor broadcasts.
    case direct
    case favorites
    case groups
    /// Followed channels, which the other filters leave out.
    case channels

    public var id: String { rawValue }

    public func matches(_ chat: ChatSummary) -> Bool {
        switch self {
        case .all: !chat.isChannel
        case .unread: chat.looksUnread && !chat.isChannel
        case .direct: chat.kind == .direct
        case .favorites: chat.favorite && !chat.isChannel
        case .groups: chat.kind == .group
        case .channels: chat.isChannel
        }
    }
}
