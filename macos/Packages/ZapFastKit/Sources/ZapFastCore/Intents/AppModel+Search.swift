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

    /// The bar's field changed: the words searched for, or, while a sender
    /// is being picked, the name that narrows the people offered. The
    /// earlier matches stay until the answer replaces them, so the count
    /// does not blink on every keystroke.
    public func setChatSearchQuery(_ text: String) {
        guard var current = search.chat else { return }
        if current.pickingSender {
            current.senderText = text
            search.chat = current
            return
        }
        guard current.query != text else { return }
        current.query = text
        askChatSearch(current, wait: true)
    }

    /// Keeps the search to one person's messages, or lifts that with nil.
    public func setChatSearchSender(_ sender: ChatSearchSender?) {
        guard var current = search.chat else { return }
        current.sender = sender
        current.pickingSender = false
        current.senderText = ""
        askChatSearch(current, wait: false)
        chatSearchFocusRequests += 1
    }

    /// The field lists the chat's people to pick a sender from.
    public func beginPickingChatSearchSender() {
        guard var current = search.chat else { return }
        current.pickingSender = true
        current.senderText = ""
        current.listShown = false
        search.chat = current
        chatSearchFocusRequests += 1
    }

    public func cancelPickingChatSearchSender() {
        guard var current = search.chat, current.pickingSender else { return }
        current.pickingSender = false
        current.senderText = ""
        search.chat = current
    }

    /// Keeps the search to one kind of message, or lifts that with nil.
    public func setChatSearchKind(_ kind: SearchKindInfo?) {
        guard var current = search.chat, current.kind != kind else { return }
        current.kind = kind
        askChatSearch(current, wait: false)
    }

    /// Keeps the in-chat search to one day, or lifts that with nil; asked
    /// at once, since a click is not typing.
    public func setChatSearchDay(_ day: Date?, calendar: Calendar = .current) {
        guard var current = search.chat else { return }
        if let day, let interval = calendar.dateInterval(of: .day, for: day) {
            current.day = interval.start
            current.dayBounds = .init(
                from: Int64(interval.start.timeIntervalSince1970), until: Int64(interval.end.timeIntervalSince1970)
            )
        } else {
            current.day = nil
            current.dayBounds = nil
        }
        askChatSearch(current, wait: false)
    }

    /// Opens or closes the list of matches under the bar.
    public func setChatSearchList(_ shown: Bool) {
        guard var current = search.chat, current.listShown != shown else { return }
        current.listShown = shown
        if shown { current.pickingSender = false }
        search.chat = current
    }

    private func askChatSearch(_ search: ChatSearch, wait: Bool) {
        var current = search
        chatSearchTask?.cancel()
        current.request = self.search.nextRequest()
        guard current.isAsking else {
            current.ids = []
            current.hits = []
            current.truncated = false
            current.pending = false
            current.current = nil
            current.listShown = false
            self.search.chat = current
            return
        }
        current.pending = true
        self.search.chat = current
        let command = BridgeCommand.searchChat(
            chat: current.chat, request: current.request, query: current.trimmedQuery,
            from: current.dayBounds?.from, until: current.dayBounds?.until,
            sender: current.sender?.info, kind: current.kind, limit: SearchStore.chatListLimit
        )
        chatSearchTask = Task { [weak self] in
            if wait { try? await Task.sleep(for: Self.searchDelay) }
            guard !Task.isCancelled else { return }
            self?.backend.send(command)
        }
    }

    /// Reveals the match at `index` of the in-chat matches.
    public func revealChatSearchHit(_ index: Int) {
        guard var current = search.chat, current.ids.indices.contains(index) else { return }
        current.current = index
        search.chat = current
        reveal(MessageKey(chat: current.chat, message: current.ids[index]))
    }

    /// Moves through the matches in the timeline: `older` goes up the chat,
    /// from the newest match the first time.
    public func stepChatSearch(older: Bool) {
        guard let current = search.chat, !current.ids.isEmpty else { return }
        let next: Int = switch current.current {
        case nil: 0
        case let index?: older ? min(index + 1, current.ids.count - 1) : max(index - 1, 0)
        }
        revealChatSearchHit(next)
    }

    /// Asks which of the days starting at `starts` have messages; `starts`
    /// ends with the end of the last day.
    public func askChatSearchDays(_ starts: [Int64]) {
        guard let current = search.chat, starts.count > 1 else { return }
        let wanted = starts.dropLast().contains { current.days[$0] == nil }
        guard wanted else { return }
        backend.send(.chatDays(chat: current.chat, starts: starts))
    }

    /// Scrolls to the first message of the day starting at `start`, as
    /// the calendar knows it.
    public func jumpToChatSearchDay(_ start: Int64) {
        guard let current = search.chat, let first = current.days[start] ?? nil else { return }
        reveal(MessageKey(chat: current.chat, message: first))
    }

    #if DEBUG
    /// The benchmark has no archive: its search is answered from the
    /// messages loaded, matched as the archive matches them.
    public func answerChatSearchFromLoaded() {
        guard let current = search.chat else { return }
        let query = current.trimmedQuery
        let found = conversations.conversation(current.chat).messages.reversed().filter { message in
            let words = query.isEmpty || searchMatches(text: messageText(message), query: query)
            let sender = switch current.sender {
            case nil: true
            case .me: message.fromMe
            case .person(let id): !message.fromMe && message.sender == id
            }
            return words && sender
        }
        search.applyChatSearchHits(
            chat: current.chat, request: current.request, ids: found.map(\.id),
            messages: Array(found.prefix(Int(SearchStore.chatListLimit))), truncated: false
        )
    }
    #endif

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
