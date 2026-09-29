import Foundation
import Observation
import ZapFastBridge

/// One chat's loaded messages and paging state.
public struct Conversation: Equatable, Sendable {
    /// Ascending by timestamp.
    public internal(set) var messages: [MessageRecord] = []
    /// The archive holds nothing earlier.
    public internal(set) var complete = false
    /// The first page was requested.
    public internal(set) var requested = false
    public internal(set) var loadingOlder = false
    /// A phone-history request is running.
    public internal(set) var fetchingPhone = false
    /// The phone has nothing older either.
    public internal(set) var phoneExhausted = false

    public func message(_ id: String) -> MessageRecord? {
        messages.first { $0.id == id }
    }

    public var oldestKey: PageKey? {
        messages.first.map { PageKey(timestamp: $0.timestamp, id: $0.id) }
    }

    /// Upstream's `Conversation::merge`: older pages prepend unseen messages;
    /// newer ones replace by id, keeping a downloaded file the fresh copy
    /// lacks.
    mutating func merge(_ incoming: [MessageRecord], older: Bool) {
        if older {
            let known = Set(messages.map(\.id))
            messages = incoming.filter { !known.contains($0.id) } + messages
        } else {
            for message in incoming {
                if let index = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[index] = message.keepingMediaPath(of: messages[index])
                } else {
                    messages.append(message)
                }
            }
        }
        messages.sort { $0.timestamp < $1.timestamp }
    }
}

public enum DownloadState: Equatable, Sendable {
    case downloading
    case failed(String)
}

public struct MessageKey: Hashable, Identifiable, Sendable {
    public var id: Self { self }

    public var chat: String
    public var message: String

    public init(chat: String, message: String) {
        self.chat = chat
        self.message = message
    }
}

/// Messages per chat, plus what is happening in each right now.
@Observable
public final class ConversationStore {
    public private(set) var conversations: [String: Conversation] = [:]
    /// Who is typing, per chat.
    public private(set) var typing: [String: Set<String>] = [:]
    public private(set) var presence: [String: Presence] = [:]
    public private(set) var downloads: [MessageKey: DownloadState] = [:]

    public struct Presence: Equatable, Sendable {
        public var online: Bool
        public var lastSeen: Date?
    }

    public init() {}

    public func conversation(_ chat: String) -> Conversation {
        conversations[chat] ?? Conversation()
    }

    // MARK: Applying events

    func markRequested(_ chat: String) {
        conversations[chat, default: Conversation()].requested = true
    }

    func markLoadingOlder(_ chat: String) {
        conversations[chat, default: Conversation()].loadingOlder = true
    }

    func markFetchingPhone(_ chat: String) {
        conversations[chat, default: Conversation()].fetchingPhone = true
    }

    /// Upstream's handling: an older page or the first page decides whether
    /// the archive has run out; a live message says nothing about history.
    /// Returns whether the chat is bare (synced with no messages), which
    /// calls for phone history.
    @discardableResult
    func applyMessages(chat: String, messages: [MessageRecord], older: Bool, complete: Bool) -> Bool {
        var conversation = conversations[chat] ?? Conversation()
        let wasEmpty = conversation.messages.isEmpty
        conversation.merge(messages, older: older)
        conversation.requested = true
        if older {
            conversation.loadingOlder = false
            conversation.complete = complete
        } else if wasEmpty {
            conversation.complete = complete
        }
        conversations[chat] = conversation
        return !older && complete && conversation.messages.isEmpty
    }

    func applyUpdated(_ message: MessageRecord) {
        guard var conversation = conversations[message.chat] else { return }
        conversation.merge([message], older: false)
        conversations[message.chat] = conversation
    }

    func applyDeleted(chat: String, id: String) {
        conversations[chat]?.messages.removeAll { $0.id == id }
    }

    func applyCleared(chat: String, through: Int64) {
        conversations[chat]?.messages.removeAll { $0.timestamp <= through }
    }

    func applyOlderFetched(chat: String, more: Bool) {
        conversations[chat]?.fetchingPhone = false
        conversations[chat]?.phoneExhausted = !more
    }

    func startDownload(_ key: MessageKey) {
        downloads[key] = .downloading
    }

    func applyMedia(chat: String, message id: String, path: String?, error: String?) {
        let key = MessageKey(chat: chat, message: id)
        if let path {
            downloads[key] = nil
            if let index = conversations[chat]?.messages.firstIndex(where: { $0.id == id }) {
                conversations[chat]?.messages[index].setMediaPath(path)
            }
        } else {
            downloads[key] = .failed(error ?? String(localized: "Download failed"))
        }
    }

    func applyTyping(chat: String, sender: String, composing: Bool) {
        if composing {
            typing[chat, default: []].insert(sender)
        } else {
            typing[chat]?.remove(sender)
            if typing[chat]?.isEmpty == true { typing[chat] = nil }
        }
    }

    func applyPresence(id: String, online: Bool, lastSeen: Int64?) {
        presence[id] = Presence(
            online: online,
            lastSeen: lastSeen.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    func forget(_ chat: String) {
        conversations[chat] = nil
        typing[chat] = nil
    }

    func clear() {
        conversations = [:]
        typing = [:]
        presence = [:]
        downloads = [:]
    }
}
