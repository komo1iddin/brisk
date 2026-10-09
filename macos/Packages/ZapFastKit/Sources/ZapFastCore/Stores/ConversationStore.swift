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
    /// Bumped by every change the store makes, so a view can tell in O(1)
    /// that nothing changed.
    public internal(set) var revision = 0
    /// Bumped only when `messages` change: paging flags leave it alone, so
    /// the timeline does not rebuild its rows for a spinner.
    public internal(set) var messagesRevision = 0

    public func message(_ id: String) -> MessageRecord? {
        messages.first { $0.id == id }
    }

    public var oldestKey: PageKey? {
        messages.first.map { PageKey(timestamp: $0.timestamp, id: $0.id) }
    }

    /// Upstream's `Conversation::merge`: older pages prepend unseen messages;
    /// newer ones replace by id, keeping a downloaded file the fresh copy
    /// lacks. Messages stay ascending by timestamp, ties in the phone's history
    /// order; the array is sorted only when a merge breaks that, not on every
    /// live message.
    mutating func merge(_ incoming: [MessageRecord], older: Bool) {
        guard !incoming.isEmpty else { return }
        if older {
            let known = Set(messages.map(\.id))
            messages = incoming.filter { !known.contains($0.id) } + messages
        } else if incoming.count <= 8 {
            // Live messages and updates: usually about the newest ones.
            for message in incoming {
                if let index = messages.lastIndex(where: { $0.id == message.id }) {
                    messages[index] = message.keepingMediaPath(of: messages[index])
                } else {
                    messages.append(message)
                }
            }
        } else {
            var positions = Dictionary(
                messages.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }
            )
            for message in incoming {
                if let index = positions[message.id] {
                    messages[index] = message.keepingMediaPath(of: messages[index])
                } else {
                    positions[message.id] = messages.count
                    messages.append(message)
                }
            }
        }
        if !isAscending {
            // Stable, as upstream's `sort_by_key`: equal keys keep their order.
            messages = messages.enumerated()
                .sorted {
                    let (a, b) = ($0.element.order, $1.element.order)
                    return a != b ? a < b : $0.offset < $1.offset
                }
                .map(\.element)
        }
    }

    private var isAscending: Bool {
        zip(messages, messages.dropFirst()).allSatisfy { $0.order <= $1.order }
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

/// A carousel card of one message.
public struct CardKey: Hashable, Sendable {
    public var message: MessageKey
    public var card: Int

    public init(message: MessageKey, card: Int) {
        self.message = message
        self.card = card
    }
}

/// Messages per chat, plus what is happening in each right now.
///
/// Each chat's conversation and each message's download live in their own
/// observable slot, so a view that reads one chat is not redrawn when
/// another chat changes (a message elsewhere, a download elsewhere).
@Observable
public final class ConversationStore {
    @ObservationIgnored private var slots: [String: Slot<Conversation>] = [:]
    @ObservationIgnored private var downloadSlots: [MessageKey: Slot<DownloadState?>] = [:]
    /// Chats the store has an entry for; a slot can exist only because a
    /// view read it.
    @ObservationIgnored private var known: Set<String> = []
    /// Who is typing, per chat, and who is online. Views read one chat's
    /// with `typing(in:)` and `presence(of:)`: typing in a busy group
    /// changes several times a second.
    @ObservationIgnored public private(set) var typing: [String: Set<String>] = [:] {
        didSet {
            for (chat, slot) in typingSlots where slot.value != typing[chat, default: []] {
                slot.value = typing[chat, default: []]
            }
        }
    }
    @ObservationIgnored public private(set) var presence: [String: Presence] = [:] {
        didSet {
            for (id, slot) in presenceSlots where slot.value != presence[id] {
                slot.value = presence[id]
            }
        }
    }
    @ObservationIgnored private var typingSlots: [String: Slot<Set<String>>] = [:]
    @ObservationIgnored private var presenceSlots: [String: Slot<Presence?>] = [:]
    /// Carousel card images on their way, by message and card index.
    public private(set) var cardDownloads: [CardKey: DownloadState] = [:]

    public struct Presence: Equatable, Sendable {
        public var online: Bool
        public var lastSeen: Date?
    }

    public init() {}

    /// Who is typing in one chat.
    public func typing(in chat: String) -> Set<String> {
        if let slot = typingSlots[chat] { return slot.value }
        let slot = Slot(typing[chat, default: []])
        typingSlots[chat] = slot
        return slot.value
    }

    /// Whether someone is online, and when they were last seen.
    public func presence(of id: String) -> Presence? {
        if let slot = presenceSlots[id] { return slot.value }
        let slot = Slot(presence[id])
        presenceSlots[id] = slot
        return slot.value
    }

    public func conversation(_ chat: String) -> Conversation {
        slot(chat).value
    }

    /// A message's download, while one is running or after it failed.
    public func download(_ key: MessageKey) -> DownloadState? {
        downloadSlot(key).value
    }

    private func slot(_ chat: String) -> Slot<Conversation> {
        if let slot = slots[chat] { return slot }
        let slot = Slot(Conversation())
        slots[chat] = slot
        return slot
    }

    private func downloadSlot(_ key: MessageKey) -> Slot<DownloadState?> {
        if let slot = downloadSlots[key] { return slot }
        let slot = Slot<DownloadState?>(nil)
        downloadSlots[key] = slot
        return slot
    }

    /// Changes one chat's conversation and bumps its revision, and its
    /// messages' revision when `messages` says they may have changed.
    private func update(_ chat: String, messages: Bool = true, _ change: (inout Conversation) -> Void) {
        let slot = slot(chat)
        var conversation = slot.value
        change(&conversation)
        conversation.revision &+= 1
        if messages { conversation.messagesRevision &+= 1 }
        slot.value = conversation
        known.insert(chat)
    }

    private func setDownload(_ key: MessageKey, _ state: DownloadState?) {
        let slot = downloadSlot(key)
        if slot.value != state { slot.value = state }
    }

    // MARK: Applying events

    func markRequested(_ chat: String) {
        update(chat, messages: false) { $0.requested = true }
    }

    func markLoadingOlder(_ chat: String) {
        update(chat, messages: false) { $0.loadingOlder = true }
    }

    func markFetchingPhone(_ chat: String) {
        update(chat, messages: false) { $0.fetchingPhone = true }
    }

    /// Upstream's handling: an older page or the first page decides whether
    /// the archive has run out; a live message says nothing about history.
    /// Returns whether the chat is bare (synced with no messages), which
    /// calls for phone history.
    @discardableResult
    func applyMessages(chat: String, messages: [MessageRecord], older: Bool, complete: Bool) -> Bool {
        var bare = false
        update(chat) { conversation in
            let wasEmpty = conversation.messages.isEmpty
            conversation.merge(messages, older: older)
            conversation.requested = true
            if older {
                conversation.loadingOlder = false
                conversation.complete = complete
            } else if wasEmpty {
                conversation.complete = complete
            }
            bare = !older && complete && conversation.messages.isEmpty
        }
        return bare
    }

    func applyUpdated(_ message: MessageRecord) {
        guard known.contains(message.chat) else { return }
        update(message.chat) { $0.merge([message], older: false) }
    }

    func applyDeleted(chat: String, id: String) {
        guard known.contains(chat) else { return }
        update(chat) { $0.messages.removeAll { $0.id == id } }
    }

    /// Nothing up to `through` is left here or on the phone.
    func applyCleared(chat: String, through: Int64) {
        update(chat) { conversation in
            conversation.messages.removeAll { $0.timestamp <= through }
            conversation.requested = true
            conversation.complete = true
            conversation.phoneExhausted = true
            conversation.loadingOlder = false
        }
        let conversation = slot(chat).value
        for (key, slot) in downloadSlots where key.chat == chat && slot.value != nil {
            if conversation.message(key.message) == nil { slot.value = nil }
        }
    }

    func applyOlderFetched(chat: String, more: Bool) {
        guard known.contains(chat) else { return }
        update(chat, messages: false) { conversation in
            conversation.fetchingPhone = false
            conversation.phoneExhausted = !more
            // Page the archive again, as upstream does: an answer that came
            // after the request timed out is archived but not yet shown.
            conversation.complete = false
        }
    }

    func startDownload(_ key: MessageKey) {
        setDownload(key, .downloading)
    }

    func startDownload(_ key: CardKey) {
        cardDownloads[key] = .downloading
    }

    func applyMedia(chat: String, message id: String, card: Int? = nil, path: String?, error: String?) {
        let key = MessageKey(chat: chat, message: id)
        let state: DownloadState? = path == nil ? .failed(error ?? String(localized: "Download failed")) : nil
        if let card {
            cardDownloads[CardKey(message: key, card: card)] = state
        } else {
            setDownload(key, state)
        }
        if let path, known.contains(chat), let index = slot(chat).value.messages.lastIndex(where: { $0.id == id }) {
            update(chat) { $0.messages[index].setMediaPath(path, card: card) }
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

    /// Readers of the chat see it empty; the slot stays so they hear of it.
    func forget(_ chat: String) {
        if known.contains(chat) {
            update(chat) { $0 = Conversation(revision: $0.revision, messagesRevision: $0.messagesRevision) }
            known.remove(chat)
        }
        typing[chat] = nil
    }

    func clear() {
        for slot in slots.values {
            slot.value = Conversation(revision: slot.value.revision &+ 1, messagesRevision: slot.value.messagesRevision &+ 1)
        }
        for slot in downloadSlots.values where slot.value != nil {
            slot.value = nil
        }
        known = []
        typing = [:]
        presence = [:]
        cardDownloads = [:]
    }
}

/// One observable value, so readers of one entry of a keyed collection are
/// told only about that entry.
@Observable
final class Slot<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

extension Conversation {
    init(revision: Int, messagesRevision: Int) {
        self.init()
        self.revision = revision
        self.messagesRevision = messagesRevision
    }
}

extension MessageRecord {
    /// Upstream's message order: by time, then the phone's history order, with
    /// messages that have none (live ones) after those that do.
    var order: MessageOrder {
        MessageOrder(timestamp: timestamp, history: historyOrder ?? .max)
    }
}

struct MessageOrder: Comparable {
    let timestamp: Int64
    let history: Int64

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.timestamp, lhs.history) < (rhs.timestamp, rhs.history)
    }
}
