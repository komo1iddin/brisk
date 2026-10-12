import Foundation
import ZapFastBridge

/// Each pane has its own bounded archive window. Opening the same chat in
/// another window cannot evict the first pane's reading position.
@MainActor
public final class TimelineReader {
    public let id = UUID().uuidString
    public let chat: String
    public let store = ConversationStore()
    var pending: (String, MessageWindowQuery)?
    var attemptedJump: UUID?
    init(chat: String, conversation: Conversation) {
        self.chat = chat
        store.seed(chat: chat, from: conversation)
    }
    public var conversation: Conversation { store.conversation(chat) }
}

extension AppModel {
    /// A loaded row can live in an older pane or media window rather than
    /// the newest cache. No archive read or unbounded history load occurs.
    public func loadedMessage(chat: String, id: String) -> MessageRecord? {
        if let message = mediaViewerMessage, message.chat == chat, message.id == id { return message }
        if let selectionReader, let reader = timelineReaders[selectionReader], reader.chat == chat,
           let message = reader.store.loadedMessage(chat: chat, id: id) { return message }
        return timelineReaders.values.lazy.filter { $0.chat == chat }.compactMap { $0.store.loadedMessage(chat: chat, id: id) }.first
            ?? conversations.loadedMessage(chat: chat, id: id)
    }

    func loadedConversation(chat: String, containing id: String) -> Conversation {
        if let selectionReader, let reader = timelineReaders[selectionReader], reader.chat == chat,
           reader.store.loadedMessage(chat: chat, id: id) != nil { return reader.conversation }
        if let reader = timelineReaders.values.first(where: {
            $0.chat == chat && $0.store.loadedMessage(chat: chat, id: id) != nil
        }) { return reader.conversation }
        return conversations.conversation(chat)
    }

    public func openTimelineReader(_ chat: String, containing id: String? = nil) -> TimelineReader {
        let seed = id.map { loadedConversation(chat: chat, containing: $0) } ?? conversations.conversation(chat)
        let reader = TimelineReader(chat: chat, conversation: seed)
        timelineReaders[reader.id] = reader
        if let key = pendingJump, key.chat == chat, reader.conversation.message(key.message) == nil {
            readWindow(.around(message: key.message), in: reader)
        }
        return reader
    }

    public func closeTimelineReader(_ reader: TimelineReader) {
        timelineReaders[reader.id] = nil
    }

    public func ensureJump(_ jump: JumpRequest?, in reader: TimelineReader) {
        guard let jump, jump.key.chat == reader.chat, reader.attemptedJump != jump.token else { return }
        reader.attemptedJump = jump.token
        guard reader.conversation.message(jump.key.message) == nil else { return }
        if case .around(let message)? = reader.pending?.1, message == jump.key.message { return }
        readWindow(.around(message: jump.key.message), in: reader)
    }

    public func reading(_ reader: TimelineReader, anchor: String?, followsNewest: Bool) {
        reader.store.retentionAnchor = followsNewest ? nil : anchor
    }

    public func loadOlder(in reader: TimelineReader) {
        let conversation = reader.conversation
        guard reader.pending == nil, !conversation.loadingOlder else { return }
        if !conversation.complete, let key = conversation.oldestKey {
            readWindow(.before(message: key.id), in: reader)
        } else if conversation.complete, !conversation.fetchingPhone, !conversation.phoneExhausted,
                  session.isConnected, phoneHistory.mayAsk(reader.chat) {
            reader.store.markFetchingPhone(reader.chat)
            conversations.markFetchingPhone(reader.chat)
            phoneHistory.asking(reader.chat, holding: conversation.messages.count)
            backend.send(.fetchOlder(chat: reader.chat))
        }
    }

    public func loadNewer(in reader: TimelineReader) {
        guard reader.pending == nil, reader.conversation.hasNewer,
              let last = reader.conversation.messages.last else { return }
        readWindow(.after(message: last.id), in: reader)
    }

    public func newest(in reader: TimelineReader) {
        guard reader.conversation.hasNewer else { return }
        readWindow(.newest, in: reader)
    }

    func readWindow(_ query: MessageWindowQuery, in reader: TimelineReader) {
        guard timelineReaders[reader.id] === reader else { return }
        let request = UUID().uuidString
        reader.pending = (request, query)
        reader.store.cancelWindowRead(reader.chat)
        if case .after = query { reader.store.markLoadingNewer(reader.chat) }
        else { reader.store.markLoadingOlder(reader.chat) }
        backend.send(.loadMessageWindow(chat: reader.chat, request: request, query: query))
    }

    func applyWindow(chat: String, request: String, messages: [MessageRecord], hasOlder: Bool,
                     hasNewer: Bool, error: String?) {
        var current = false
        if let pending = defaultWindowRequests[chat], pending.0 == request {
            current = true
            defaultWindowRequests[chat] = nil
            if error == nil {
                conversations.applyWindow(chat: chat, messages: messages, query: pending.1,
                                          hasOlder: hasOlder, hasNewer: hasNewer)
            } else { conversations.cancelWindowRead(chat) }
            if pendingJump?.chat == chat { continueJump() }
        }
        for reader in timelineReaders.values where reader.chat == chat && reader.pending?.0 == request {
            current = true
            let query = reader.pending!.1
            reader.pending = nil
            if error == nil {
                reader.store.applyWindow(chat: chat, messages: messages, query: query,
                                         hasOlder: hasOlder, hasNewer: hasNewer)
            } else { reader.store.cancelWindowRead(chat) }
        }
        if current, let error { post(.error, error) }
        // Only a current request can report failure; retired panes and stale
        // replies are ignored, including after clear/unlink/account switching.
    }

    func applyTimelineEvent(_ event: BridgeEvent) {
        if let current = mediaViewerMessage {
            switch event {
            case let .messageUpdated(message) where message.chat == current.chat && message.id == current.id:
                mediaViewerMessage = MediaGallery.kind(of: message) == nil ? nil : message.keepingMediaPath(of: current)
            case let .messages(chat, messages, _, _) where chat == current.chat:
                if let message = messages.first(where: { $0.id == current.id }) {
                    mediaViewerMessage = MediaGallery.kind(of: message) == nil ? nil : message.keepingMediaPath(of: current)
                }
            case let .media(chat, id, card, path?, _) where chat == current.chat && id == current.id:
                mediaViewerMessage?.setMediaPath(path, card: card.map(Int.init))
            case let .messageDeleted(chat, id) where chat == current.chat && id == current.id:
                mediaViewerMessage = nil
            case let .chatCleared(chat, through) where chat == current.chat && current.timestamp <= through:
                closeMediaViewer()
            case .chatRemoved(let chat) where chat == current.chat: closeMediaViewer()
            case .link(.loggedOut): closeMediaViewer()
            default: break
            }
        }
        for reader in timelineReaders.values {
            let chat = reader.chat
            switch event {
            case let .messages(id, messages, older, complete) where id == chat && !older:
                let state = reader.conversation
                let fresh = state.hasNewer ? messages.filter { state.message($0.id) != nil } : messages
                reader.store.applyMessages(chat: chat, messages: fresh, older: false, complete: complete)
            case let .messages(id, messages, older, complete) where id == chat && older
                && (reader.conversation.fetchingPhone || reader.conversation.messages.isEmpty):
                reader.store.applyMessages(chat: chat, messages: messages, older: true, complete: complete)
            case let .messageUpdated(message) where message.chat == chat: reader.store.applyUpdated(message)
            case let .messageDeleted(id, message) where id == chat: reader.store.applyDeleted(chat: chat, id: message)
            case let .chatCleared(id, through) where id == chat:
                reader.pending = nil
                reader.store.applyCleared(chat: chat, through: through)
            case .chatRemoved(let id) where id == chat:
                reader.pending = nil
                reader.store.forget(chat)
            case let .media(id, message, card, path, error) where id == chat:
                reader.store.applyMedia(chat: chat, message: message, card: card.map(Int.init), path: path, error: error)
            case let .olderFetched(id, more) where id == chat:
                let fetching = reader.conversation.fetchingPhone
                reader.store.applyOlderFetched(chat: chat, more: more)
                if fetching {
                    if reader.conversation.messages.isEmpty { readWindow(.newest, in: reader) }
                    else { loadOlder(in: reader) }
                }
            default: break
            }
        }
    }
}
