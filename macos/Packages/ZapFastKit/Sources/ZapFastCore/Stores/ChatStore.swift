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
    /// Labels in creation order; kept on this computer only.
    public private(set) var labels: [LabelInfo] = []

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
    /// A label lists every chat wearing it, channels included, because
    /// someone put each of them there.
    public func visibleChats(
        filter: ChatFilter,
        query: String,
        archived: Bool,
        label: String? = nil
    ) -> [ChatSummary] {
        let needle = searchKey(text: query.trimmingCharacters(in: .whitespacesAndNewlines))
        let searching = !needle.isEmpty
        let filtered = chats.values.filter { chat in
            guard !chat.locked else { return false }
            if searching {
                return matches(chat, needle: needle)
            }
            guard chat.archived == archived else { return false }
            if archived { return true }
            if let label { return chat.labels.contains(label) }
            return filter.matches(chat)
        }
        let favoritesOrder = !searching && !archived && label == nil && filter == .favorites
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

    /// Where messages can be forwarded (upstream's `forwardable`): not
    /// broadcast lists or channels, not read-only groups, not locked chats;
    /// newest activity first.
    public func forwardTargets(query: String) -> [ChatSummary] {
        let needle = searchKey(text: query.trimmingCharacters(in: .whitespacesAndNewlines))
        return chats.values
            .filter { $0.kind != .broadcast && !$0.readOnly && !$0.locked }
            .filter { needle.isEmpty || matchesName($0, needle: needle) }
            .sorted { $0.lastActivity != $1.lastActivity ? $0.lastActivity > $1.lastActivity : $0.id < $1.id }
    }

    /// Chats WhatsApp's chat lock hides, for the Locked folder: newest
    /// activity first, archived ones included.
    public func lockedChats(query: String = "") -> [ChatSummary] {
        let needle = searchKey(text: query.trimmingCharacters(in: .whitespacesAndNewlines))
        return chats.values
            .filter { $0.locked && (needle.isEmpty || matches($0, needle: needle)) }
            .sorted { $0.lastActivity != $1.lastActivity ? $0.lastActivity > $1.lastActivity : $0.id < $1.id }
    }

    public var lockedCount: Int {
        chats.values.count(where: \.locked)
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
        matchesName(chat, needle: needle)
            || (chat.last.map { searchKey(text: $0.summary).contains(needle) } ?? false)
    }

    private func matchesName(_ chat: ChatSummary, needle: String) -> Bool {
        searchKey(text: title(for: chat)).contains(needle)
            || (chat.phone.map { searchKey(text: $0).contains(needle) } ?? false)
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

    /// People to start a chat with (upstream's `new_chat`): saved contacts
    /// and people we already have a direct chat with, only those with a
    /// phone number, never us or a locked chat, by name.
    public func newChatCandidates(query: String) -> [(id: String, name: String)] {
        let needle = searchKey(text: query.trimmingCharacters(in: .whitespacesAndNewlines))
        var ids = Set(contacts.keys)
        for chat in chats.values where chat.kind == .direct {
            ids.insert(chat.id)
        }
        return ids
            .filter { id in
                guard let phone = phoneOf(id: id), !session.isOurs(id), chats[id]?.locked != true else { return false }
                return needle.isEmpty
                    || searchKey(text: personName(id, hint: nil)).contains(needle)
                    || phone.filter(\.isNumber).contains(needle)
            }
            .map { (id: $0, name: personName($0, hint: nil)) }
            .sorted { a, b in
                let left = searchKey(text: a.name), right = searchKey(text: b.name)
                return left != right ? left < right : a.id < b.id
            }
    }

    /// Whether "Message yourself" belongs in a list searched for `query`
    /// (upstream's `offers_self`).
    public func offersSelf(query: String) -> Bool {
        guard let me = session.account?.id, chats[me]?.locked != true else { return false }
        let needle = searchKey(text: query.trimmingCharacters(in: .whitespacesAndNewlines))
        if needle.isEmpty { return true }
        return [selfTitle, String(localized: "Message yourself"), String(localized: "You")]
            .contains { searchKey(text: $0).contains(needle) }
    }

    /// A group's members for its info panel (upstream's `participant_list`):
    /// named people alphabetically, then bare numbers, then us last.
    public func members(of chat: ChatSummary) -> [(id: String, name: String)] {
        var named: [(id: String, name: String)] = []
        var numbers: [(id: String, name: String)] = []
        for id in chat.participants where !session.isOurs(id) {
            let name = personName(id, hint: nil)
            if name.hasPrefix("+") || name == String(localized: "Unknown") {
                numbers.append((id, name))
            } else {
                named.append((id, name))
            }
        }
        named.sort { a, b in
            let left = a.name.trimmingPrefix("~").lowercased(), right = b.name.trimmingPrefix("~").lowercased()
            return left != right ? left < right : a.id < b.id
        }
        numbers.sort { $0.name < $1.name }
        if let me = chat.participants.first(where: session.isOurs) {
            numbers.append((me, String(localized: "You")))
        }
        return named + numbers
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

    func replaceLabels(_ list: [LabelInfo]) {
        labels = list
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
        labels = []
    }
}

extension Optional where Wrapped == String {
    /// The string, unless it is missing or blank.
    var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return self
    }
}
