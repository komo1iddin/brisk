/// Searching the chat list and a chat's messages.
///
/// Part of `AppModel`, in a file of its own so that one file is one
/// subject; the state these read and write lives on the class.

import Foundation
import ZapFastBridge

extension AppModel {
    // MARK: Intents: search

    /// Pause after the last keystroke before the archive is asked.
    static let searchDelay: Duration = .milliseconds(200)

    /// The sidebar's search text changed: ask for matching messages once
    /// typing pauses. Locked chats stay out, as upstream keeps them.
    public func searchMessages(_ text: String) {
        messageSearchTask?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        wantedMessageQuery = query
        guard !query.isEmpty else {
            search.clearMessageHits()
            return
        }
        messageSearchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDelay)
            guard !Task.isCancelled else { return }
            self?.backend.send(.searchMessages(query: query))
        }
    }

    public func focusSidebarSearch() {
        sidebarSearchRequests += 1
    }

    /// Opens the search inside the open chat, keeping one already open,
    /// and puts the cursor in its field. The info over the chat closes.
    public func openChatSearch(in chat: String? = nil) {
        guard let chat = chat ?? selectedChatID else { return }
        closeInfo()
        if search.chat?.chat != chat { search.chat = ChatSearch(chat: chat) }
        chatSearchFocusRequests += 1
    }

    public func closeChatSearch() {
        chatSearchTask?.cancel()
        search.chat = nil
    }

    /// The in-chat search text changed. The earlier matches stay listed
    /// until the answer replaces them, so the list does not blink empty on
    /// every keystroke.
    public func setChatSearchQuery(_ text: String) {
        guard var current = search.chat, current.query != text else { return }
        current.query = text
        askChatSearch(current, wait: true)
    }

    /// Keeps the in-chat search to one day, or lifts that with nil; asked
    /// at once, since a click is not typing.
    public func setChatSearchDay(_ day: Date?, calendar: Calendar = .current) {
        guard var current = search.chat else { return }
        if let day, let interval = calendar.dateInterval(of: .day, for: day) {
            current.day = interval.start
            current.dayBounds = (Int64(interval.start.timeIntervalSince1970), Int64(interval.end.timeIntervalSince1970))
        } else {
            current.day = nil
            current.dayBounds = nil
        }
        askChatSearch(current, wait: false)
    }

    private func askChatSearch(_ search: ChatSearch, wait: Bool) {
        var current = search
        chatSearchTask?.cancel()
        guard current.isAsking else {
            current.hits = []
            current.truncated = false
            current.pending = false
            current.selected = nil
            self.search.chat = current
            return
        }
        current.pending = true
        self.search.chat = current
        let chat = current.chat, query = current.trimmedQuery, bounds = current.dayBounds
        chatSearchTask = Task { [weak self] in
            if wait { try? await Task.sleep(for: Self.searchDelay) }
            guard !Task.isCancelled else { return }
            self?.backend.send(.searchChatMessages(chat: chat, query: query, from: bounds?.from, until: bounds?.until))
        }
    }

    /// Reveals the match at `index` of the in-chat results.
    public func revealChatSearchHit(_ index: Int) {
        guard var current = search.chat, current.hits.indices.contains(index) else { return }
        current.selected = index
        search.chat = current
        open(current.hits[index])
    }

    /// Moves through the in-chat results: `older` goes down the list, which
    /// is newest first, as Find Next goes down a page.
    public func stepChatSearch(older: Bool) {
        guard let current = search.chat, !current.hits.isEmpty else { return }
        let next: Int = switch current.selected {
        case nil: 0
        case let index?: older ? min(index + 1, current.hits.count - 1) : max(index - 1, 0)
        }
        revealChatSearchHit(next)
    }

    /// Opens a message's chat and scrolls to it, loading the archive up to
    /// it first when it is older than what is loaded.
    public func open(_ message: MessageRecord) {
        reveal(MessageKey(chat: message.chat, message: message.id))
    }

    /// Scrolls to the message a reply quotes, as clicking a quote does
    /// upstream. A quote of a message the archive never had ends with the
    /// backend saying so.
    public func showQuoted(in message: MessageRecord) {
        guard let quoted = message.quoted, !quoted.id.isEmpty else { return }
        reveal(MessageKey(chat: message.chat, message: quoted.id))
    }

    public func reveal(_ key: MessageKey) {
        if selectedChatID != key.chat { selectedChatID = key.chat }
        pendingJump = key
        jumpAskedArchive = false
        continueJump()
    }

    /// Finishes a pending jump once its message is loaded, or asks the
    /// archive for everything from it up to what is loaded. With no page
    /// loaded yet, the first page is on its way and this runs again then.
    func continueJump() {
        guard let key = pendingJump else { return }
        let conversation = conversations.conversation(key.chat)
        if conversation.message(key.message) != nil {
            pendingJump = nil
            jump = JumpRequest(key: key)
            flash(key)
        } else if jumpAskedArchive, !conversation.loadingOlder {
            // The archive answered without it; the backend has said why.
            pendingJump = nil
        } else if !jumpAskedArchive, !conversation.loadingOlder, let oldest = conversation.oldestKey {
            jumpAskedArchive = true
            conversations.markLoadingOlder(key.chat)
            backend.send(.loadUntil(chat: key.chat, message: key.message, before: oldest))
        }
    }

    private func flash(_ key: MessageKey) {
        highlighted = key
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.highlighted = nil
        }
    }

    public func dismissNotice(_ notice: Notice) {
        notices.removeAll { $0.id == notice.id }
    }
}
