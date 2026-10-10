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

    /// The search inside a chat, while its bar is open.
    public internal(set) var chat: ChatSearch?

    public init() {}

    /// Matches an answer carries whole, for the list under the bar; the
    /// rest arrive as ids, which is all stepping through them needs.
    public static let chatListLimit: UInt32 = 200

    /// Numbers each in-chat search sent, so only the answer to the last one
    /// is shown.
    @ObservationIgnored private var lastRequest: UInt64 = 0

    func nextRequest() -> UInt64 {
        lastRequest += 1
        return lastRequest
    }

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

    /// An answer to the in-chat search. The match on screen stays the
    /// current one when the new answer still has it.
    func applyChatSearchHits(chat id: String, request: UInt64, ids: [String], messages: [MessageRecord], truncated: Bool) {
        guard var search = chat, search.chat == id, search.request == request else { return }
        let shown = search.currentID
        search.ids = ids
        search.hits = messages
        search.truncated = truncated
        search.pending = false
        search.current = shown.flatMap { ids.firstIndex(of: $0) }
        chat = search
    }

    /// Which days of a span have messages, and the first of each, for the
    /// calendar.
    func applyDays(chat id: String, starts: [Int64], first: [String?]) {
        guard var search = chat, search.chat == id else { return }
        for (start, message) in zip(starts, first) {
            search.days[start] = .some(message)
        }
        chat = search
    }

    /// A chat was cleared up to `through`, or deleted.
    func dropHits(in id: String, through: Int64) {
        messageHits.removeAll { $0.chat == id && $0.timestamp <= through }
        guard var search = chat, search.chat == id else { return }
        let gone = Set(search.hits.filter { $0.timestamp <= through }.map(\.id))
        search.hits.removeAll { gone.contains($0.id) }
        search.ids.removeAll { gone.contains($0) }
        search.current = nil
        search.days = [:]
        chat = search
    }

    func clear() {
        clearMessageHits()
        chat = nil
    }
}

/// Whose messages the in-chat search keeps.
public enum ChatSearchSender: Equatable, Hashable, Sendable {
    case me
    case person(String)

    var info: SearchSenderInfo {
        switch self {
        case .me: .me
        case .person(let id): .person(id: id)
        }
    }
}

/// The search inside one chat: words, and any of a sender, a kind and a
/// day, all of which must hold. Its matches are walked in the timeline,
/// newest first; the list under the bar shows them too, when asked.
public struct ChatSearch: Equatable, Sendable {
    public let chat: String
    public internal(set) var query = ""
    public internal(set) var sender: ChatSearchSender?
    public internal(set) var kind: SearchKindInfo?
    /// Only messages from this day, its first and first-after instants in
    /// Unix seconds.
    public internal(set) var day: Date?
    public internal(set) var dayBounds: DayBounds?

    /// The request whose answer is shown, or is on its way.
    public internal(set) var request: UInt64 = 0
    /// Every match, newest first.
    public internal(set) var ids: [String] = []
    /// The newest matches whole, for the list.
    public internal(set) var hits: [MessageRecord] = []
    /// More matched than `ids` holds.
    public internal(set) var truncated = false
    /// An answer to the current search is on its way.
    public internal(set) var pending = false
    /// The match revealed in the timeline, an index into `ids`.
    public internal(set) var current: Int?

    /// The list of matches is open under the bar: by itself with each new
    /// search, until a match is picked.
    public internal(set) var listShown = false
    /// The bar's field names people to pick a sender from, instead of words.
    public internal(set) var pickingSender = false
    public internal(set) var senderText = ""

    /// The first message of each day the calendar asked about (`nil` for a
    /// day without any), by the day's first instant in Unix seconds.
    public internal(set) var days: [Int64: String?] = [:]

    public struct DayBounds: Equatable, Sendable {
        public let from: Int64
        public let until: Int64
    }

    public init(chat: String) {
        self.chat = chat
    }

    public var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A sender, a kind or a day lists their messages with no words.
    public var isAsking: Bool {
        !trimmedQuery.isEmpty || sender != nil || kind != nil || day != nil
    }

    public var currentID: String? {
        current.flatMap { ids.indices.contains($0) ? ids[$0] : nil }
    }

    /// What the bar's field shows: words, or a person's name being picked.
    public var fieldText: String {
        pickingSender ? senderText : query
    }
}
