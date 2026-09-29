import Foundation
import Observation
import ZapFastBridge

/// Chats, contacts, and drafts, and the rules for naming them.
@Observable
public final class ChatStore {
    public private(set) var chats: [String: ChatSummary] = [:]
    public private(set) var contacts: [String: ContactRecord] = [:]
    /// Unsent composer text per chat, as the backend stored it.
    public private(set) var drafts: [String: String] = [:]

    private let session: SessionStore

    public init(session: SessionStore) {
        self.session = session
    }

    public func chat(_ id: String) -> ChatSummary? {
        chats[id]
    }

    // MARK: Listing

    /// Chats for the sidebar, in upstream's order: pinned first (newest pin
    /// first), then by latest activity.
    public func visibleChats(filter: ChatFilter, query: String, archived: Bool) -> [ChatSummary] {
        let needle = searchKey(text: query.trimmingCharacters(in: .whitespacesAndNewlines))
        let searching = !needle.isEmpty
        let filtered = chats.values.filter { chat in
            guard !chat.locked else { return false }
            if searching {
                return matches(chat, needle: needle)
            }
            return chat.archived == archived && (archived || filter.matches(chat))
        }
        let favoritesOrder = !searching && !archived && filter == .favorites
        return filtered.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            if a.pinned {
                return a.pinnedAt != b.pinnedAt ? a.pinnedAt > b.pinnedAt : a.id < b.id
            }
            if favoritesOrder, a.favoritePosition != b.favoritePosition {
                return a.favoritePosition < b.favoritePosition
            }
            return a.lastActivity != b.lastActivity ? a.lastActivity > b.lastActivity : a.id < b.id
        }
    }

    public var archivedCount: Int {
        chats.values.count { $0.archived && !$0.locked }
    }

    public var archivedUnread: Int {
        chats.values.count { $0.archived && !$0.locked && $0.looksUnread }
    }

    /// Chats with something unread, for the Dock badge. Muted chats and
    /// channels do not count, as on the phone.
    public var unreadChatCount: Int {
        chats.values.count { chat in
            chat.unread > 0 && !chat.archived && !chat.locked && !chat.isChannel
                && !isMuted(chat)
        }
    }

    public func isMuted(_ chat: ChatSummary, now: Date = .now) -> Bool {
        guard let until = chat.mutedUntil else { return false }
        return until == 0 || until > Int64(now.timeIntervalSince1970)
    }

    private func matches(_ chat: ChatSummary, needle: String) -> Bool {
        searchKey(text: title(for: chat)).contains(needle)
            || (chat.phone.map { searchKey(text: $0).contains(needle) } ?? false)
            || (chat.last.map { searchKey(text: $0.summary).contains(needle) } ?? false)
    }

    // MARK: Naming (ported from upstream `App::chat_title` and friends)

    /// The chat list and header title.
    public func title(for chat: ChatSummary) -> String {
        if chat.kind == .group {
            let untitled = chat.name.trimmingCharacters(in: .whitespaces).isEmpty
                || (chat.name == "Group" && !chat.groupSubjectKnown)
            if untitled {
                let members = participantNames(chat)
                return members.isEmpty ? String(localized: "Group") : members
            }
            return chat.name
        }
        if session.isOurs(chat.id) {
            return selfTitle
        }
        return personName(chat.id, hint: nil)
    }

    /// A person's name, or "You" for our own id.
    public func displayName(_ id: String, hint: String? = nil) -> String {
        session.isOurs(id) ? String(localized: "You") : personName(id, hint: hint)
    }

    /// Saved names first, as WhatsApp does; a profile name wears a tilde.
    public func personName(_ id: String, hint: String?) -> String {
        let contact = contacts[id]
        if let saved = contact?.fullName.nonEmpty {
            return saved
        }
        if let called = contact?.pushName.nonEmpty ?? hint.nonEmpty {
            return "~\(called)"
        }
        if let chat = chats[id], !chat.name.isEmpty, !chat.name.allSatisfy(\.isNumber) {
            return chat.name
        }
        return phoneOf(id: id) ?? String(localized: "Unknown")
    }

    /// "Name (You)" as on the phone.
    public var selfTitle: String {
        if let name = session.account?.name.nonEmpty {
            return String(localized: "\(name) (You)")
        }
        return String(localized: "You")
    }

    /// Short member names for an untitled group or a header subtitle.
    public func participantNames(_ chat: ChatSummary, limit: Int = 6) -> String {
        let names = chat.participants
            .filter { !session.isOurs($0) }
            .prefix(limit)
            .map { id in contacts[id]?.firstName.nonEmpty ?? personName(id, hint: nil) }
        return names.joined(separator: ", ")
    }

    // MARK: Applying events

    func replaceAll(_ list: [ChatSummary]) {
        chats = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    }

    func upsert(_ chat: ChatSummary) {
        chats[chat.id] = chat
    }

    func remove(_ id: String) {
        chats[id] = nil
        drafts[id] = nil
    }

    func replaceContacts(_ list: [ContactRecord]) {
        for contact in list {
            contacts[contact.id] = contact
        }
    }

    func replaceDrafts(_ list: [Draft]) {
        drafts = Dictionary(list.map { ($0.chat, $0.text) }, uniquingKeysWith: { _, new in new })
    }

    func setDraft(_ text: String, for chat: String) {
        drafts[chat] = text.isEmpty ? nil : text
    }

    func clear() {
        chats = [:]
        contacts = [:]
        drafts = [:]
    }
}

extension Optional where Wrapped == String {
    /// The string, unless it is missing or blank.
    var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return self
    }
}
