import Foundation
import Observation
import ZapFastBridge

/// Chats, contacts, and drafts, and the rules for naming them.
@Observable
public final class ChatStore {
    public private(set) var chats: [String: ChatSummary] = [:] {
        didSet {
            untracked = chats
            var tally = Tally()
            for chat in chats.values { tally.count(chat, muted: isMuted(chat)) }
            // Set only when they change: the menu bar icon, the Dock badge and
            // the sidebar's filter menu read these, and would otherwise be
            // redrawn by every message in any chat.
            if tally.pinned != pinnedCount { pinnedCount = tally.pinned }
            if tally.unread != unreadChatCount { unreadChatCount = tally.unread }
            if tally.channels != channelCount { channelCount = tally.channels }
            if tally.mutedChannels != mutedChannelCount { mutedChannelCount = tally.mutedChannels }
            for (id, slot) in slots where slot.value != chats[id] {
                slot.value = chats[id]
            }
        }
    }
    /// `chats` again, readable without being observed.
    @ObservationIgnored private var untracked: [String: ChatSummary] = [:]
    /// One observable slot per chat asked for by id, so a view showing one
    /// chat is not redrawn by every other chat that changes.
    @ObservationIgnored private var slots: [String: Slot<ChatSummary?>] = [:]
    /// Pinned chats, kept apart so menus that check the pin limit are not
    /// redrawn by every chat that changes.
    public private(set) var pinnedCount = 0
    /// Chats with unread messages that count toward badges: not archived,
    /// locked, a channel or muted.
    public private(set) var unreadChatCount = 0
    /// Followed channels, and how many of them are muted.
    public private(set) var channelCount = 0
    public private(set) var mutedChannelCount = 0
    public private(set) var contacts: [String: ContactRecord] = [:]
    /// Unsent composer text per chat, as the backend stored it. Views read
    /// one chat's with `draft(for:)`.
    @ObservationIgnored public private(set) var drafts: [String: String] = [:] {
        didSet {
            for (id, slot) in draftSlots where slot.value != drafts[id] {
                slot.value = drafts[id]
            }
        }
    }
    @ObservationIgnored private var draftSlots: [String: Slot<String?>] = [:]
    /// Labels in creation order; kept on this computer only.
    public private(set) var labels: [LabelInfo] = []

    private let session: SessionStore

    public init(session: SessionStore) {
        self.session = session
    }

    /// One chat's draft; a row reading it is not redrawn by another's.
    public func draft(for id: String) -> String? {
        if let slot = draftSlots[id] { return slot.value }
        let slot = Slot(drafts[id])
        draftSlots[id] = slot
        return slot.value
    }

    public func chat(_ id: String) -> ChatSummary? {
        if let slot = slots[id] { return slot.value }
        let slot = Slot(untracked[id])
        slots[id] = slot
        return slot.value
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
        label: String? = nil,
        kept: Set<String> = []
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
            // A chat opened from the Unread list stays in it once read.
            return filter.matches(chat) || (filter == .unread && kept.contains(chat.id))
        }
        let favoritesOrder = !searching && !archived && label == nil && filter == .favorites
        // Positions are sorted, not the chats: moving whole summaries about
        // was most of the sidebar's work for each message.
        let order = filtered.indices.sorted { i, j in
            let a = filtered[i], b = filtered[j]
            if a.pinned != b.pinned { return a.pinned }
            if a.pinned {
                return a.pinnedAt != b.pinnedAt ? a.pinnedAt > b.pinnedAt : a.id < b.id
            }
            if favoritesOrder, a.favoritePosition != b.favoritePosition {
                return a.favoritePosition < b.favoritePosition
            }
            return a.lastActivity != b.lastActivity ? a.lastActivity > b.lastActivity : a.id < b.id
        }
        return order.map { filtered[$0] }
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
    /// The counts kept beside the chats.
    private struct Tally {
        var pinned = 0
        var unread = 0
        var channels = 0
        var mutedChannels = 0

        mutating func count(_ chat: ChatSummary, muted: Bool) {
            if chat.pinned { pinned += 1 }
            if chat.isChannel {
                channels += 1
                if muted { mutedChannels += 1 }
            } else if chat.unread > 0, !chat.archived, !chat.locked, !muted {
                unread += 1
            }
        }
    }

    /// Followed channels, for muting or unmuting them all.
    public var channels: [ChatSummary] {
        chats.values.filter(\.isChannel)
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
        return PhoneFormat.display(id: id) ?? String(localized: "Unknown")
    }

    /// The number shown beside a group member's name when they are not a
    /// saved contact, as WhatsApp does ("~Aziza  +998 90 123 45 67"); nil
    /// for a contact, for us, and for a privacy id whose number is unknown.
    public func unsavedPhone(_ id: String) -> String? {
        guard contacts[id]?.fullName.nonEmpty == nil, !session.isOurs(id) else { return nil }
        // Asked of every run in a group each time its rows are made; the
        // answer for an id never changes, and finding it costs a call into
        // Rust and libphonenumber.
        if let known = phones[id] { return known }
        let phone = PhoneFormat.display(id: id)
        phones[id] = phone
        return phone
    }

    @ObservationIgnored private var phones: [String: String?] = [:]

    /// A person's name colour in a chat (`NameColors`): in a group, one of
    /// their own among its members; elsewhere the one their id leads to.
    /// Read without observing the chats: a timeline asking for every row
    /// would otherwise be made again by any message in any chat. New members
    /// take their colours the next time the rows are made.
    public func nameColor(_ person: String, in chat: String) -> Int {
        guard let members = untracked[chat]?.participants, !members.isEmpty else { return NameColors.hashed(person) }
        if let known = nameColors[chat], known.members == members {
            return known.colors[person] ?? NameColors.hashed(person)
        }
        let colors = NameColors.assign(members: members)
        nameColors[chat] = (members, colors)
        return colors[person] ?? NameColors.hashed(person)
    }

    /// Each group's colours, made again when its members change.
    @ObservationIgnored private var nameColors: [String: (members: [String], colors: [String: Int])] = [:]

    /// "Name (You)" as on the phone.
    public var selfTitle: String {
        if let name = session.account?.name.nonEmpty {
            return String(localized: "\(name) (You)")
        }
        return String(localized: "You")
    }

    /// Short member names for an untitled group or a header subtitle
    /// (upstream's `participant_names`, for the first `limit` members: the
    /// title is asked for on every row and search keystroke, so it cannot
    /// look at everyone).
    public func participantNames(_ chat: ChatSummary, limit: Int = 6) -> String {
        let names = chat.participants
            .filter { !session.isOurs($0) }
            .prefix(limit)
            .map(shortName)
        return names.joined(separator: ", ")
    }

    /// A member's saved first name, whole, as WhatsApp shows it ("My Dih"
    /// can be a first name). Without one (a profile name, or a contact
    /// synced before first names were kept) the first word of the name, so
    /// the line stays short. A number is not split.
    func shortName(_ id: String) -> String {
        if let first = contacts[id]?.firstName.nonEmpty { return first }
        let name = personName(id, hint: nil)
        if name.hasPrefix("+") || name == String(localized: "Unknown") { return name }
        let bare = name.drop { $0 == "~" }
        return bare.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? String(bare)
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

    /// People found by the chat list's search with no chat yet (upstream's
    /// `matching_contacts`): saved contacts with a number, by name, at most
    /// fifteen, and none while nothing is typed.
    public func matchingContacts(query: String) -> [(id: String, name: String)] {
        guard !searchKey(text: query.trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty else { return [] }
        return Array(newChatCandidates(query: query).filter { chats[$0.id] == nil && contacts[$0.id] != nil }.prefix(15))
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
