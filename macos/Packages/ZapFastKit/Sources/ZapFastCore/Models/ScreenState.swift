/// What `AppModel` is showing or waiting to be told, as values.
///
/// These are the sheets and panels a view opens, and the transient state it
/// reads: a forward in flight, a deletion waiting to be confirmed, where the
/// timeline should scroll. They carry no behaviour; `AppModel` owns that.

import Foundation
import ZapFastBridge

public struct ForwardRequest: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let chat: String
    /// Message ids in the source chat.
    public let messages: [String]
}

/// Clearing or deleting a chat, waiting to be confirmed.
/// A message waiting for the person to confirm its deletion.
public struct MessageDeletion: Identifiable, Equatable, Sendable {
    public var id: MessageKey { key }
    public let key: MessageKey
    public let forEveryone: Bool
}

public struct ChatConfirmation: Identifiable, Equatable, Sendable {
    public enum Action: Sendable { case clear, delete, lock, leave }
    public var id: String { chat }
    public let chat: String
    public let action: Action
}

/// A chat's export, waiting to be told how.
public struct ChatExportRequest: Identifiable, Equatable, Sendable {
    public var id: String { chat }
    public let chat: String
}

/// A business message's list of choices, open for one of its buttons.
public struct InteractiveListRequest: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let key: MessageKey
    public let button: Int
}

/// A shared sticker pack being fetched, shown, or that failed to open.
public struct StickerPackPreview: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case loading
        case ready(pack: StickerPackInfo, publisher: String)
        case failed(String)
    }

    public let id = UUID()
    /// The chat it was shared in, where its stickers can be sent.
    public let chat: String
    public internal(set) var state: State
}

public struct MessageSelection: Equatable, Sendable {
    public let chat: String
    /// In chat order.
    public internal(set) var ids: [String]
    /// The last message clicked, where a Shift-click range starts.
    var anchor: String
}

/// A drag across messages: where it began, what was picked then, and whether
/// it picks what it passes over or puts it back. The timeline keeps it for
/// the length of the drag.
public struct MessageSweep: Sendable {
    let chat: String
    let anchor: String
    let base: Set<String>
    let adds: Bool
}

/// The selected messages for the share menu.
public struct SelectionShare: Equatable, Sendable {
    public let text: String?
    public let files: [URL]

    public var isEmpty: Bool { text == nil && files.isEmpty }
}

public struct UnsentVoice: Equatable, Sendable {
    public let chat: String
    public let samples: [Float]

    /// Whole seconds, at least one, as upstream's strip rounds them.
    public var seconds: Int {
        max(1, Int((Double(samples.count) / Double(voiceSampleRate())).rounded()))
    }
}

/// Upstream's `UnreadDivider`: how many messages were unread when the chat
/// was opened, and the first of them once its page is loaded.
public struct UnreadDivider: Equatable, Sendable {
    public let chat: String
    public let count: UInt32
    public internal(set) var message: String?
}

public enum TimelineScroll: Sendable {
    case pageUp, pageDown, top, bottom
}

public struct TimelineScrollRequest: Equatable, Sendable {
    public let kind: TimelineScroll
    public let token = UUID()
}

public struct JumpRequest: Equatable, Sendable {
    public let key: MessageKey
    public let token = UUID()
}

public struct Notice: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case info, error }
    public let id = UUID()
    public let kind: Kind
    public let text: String
}
