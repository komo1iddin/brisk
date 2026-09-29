import Foundation
import Observation
import ZapFastBridge

/// Message search: the sidebar's search across every chat, and the search
/// inside the open chat. Both ask the archive and keep only answers to the
/// query still being asked, as upstream does.
@Observable
public final class SearchStore {
    /// Messages matching the sidebar search, newest first.
    public private(set) var messageHits: [MessageRecord] = []
    /// The query `messageHits` answers.
    public private(set) var messageQuery = ""

    /// The search inside a chat, while its panel is open.
    public internal(set) var chat: ChatSearch?

    public init() {}

    /// Upstream shows this many in-chat matches (`CHAT_SEARCH_LIMIT`).
    public static let chatLimit = 80

    // MARK: Applying events

    func applyMessageHits(query: String, messages: [MessageRecord], wanted: String) {
        guard query == wanted else { return }
        messageQuery = query
        messageHits = messages
    }

    func clearMessageHits() {
        messageQuery = ""
        messageHits = []
    }

    func applyChatHits(chat id: String, query: String, messages: [MessageRecord], truncated: Bool) {
        guard var search = chat, search.chat == id, search.trimmedQuery == query else { return }
        search.hits = messages
        search.truncated = truncated
        search.pending = false
        search.selected = nil
        chat = search
    }

    /// A chat was cleared up to `through`, or deleted.
    func dropHits(in id: String, through: Int64) {
        messageHits.removeAll { $0.chat == id && $0.timestamp <= through }
        if chat?.chat == id {
            chat?.hits.removeAll { $0.timestamp <= through }
            chat?.selected = nil
        }
    }

    func clear() {
        clearMessageHits()
        chat = nil
    }
}

/// The search inside one chat.
public struct ChatSearch: Equatable, Sendable {
    public let chat: String
    public internal(set) var query = ""
    /// Matches, newest first.
    public internal(set) var hits: [MessageRecord] = []
    /// The archive held more than `SearchStore.chatLimit` matches.
    public internal(set) var truncated = false
    /// An answer to the current query is on its way.
    public internal(set) var pending = false
    /// The match last revealed in the timeline, an index into `hits`.
    public internal(set) var selected: Int?

    public var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
