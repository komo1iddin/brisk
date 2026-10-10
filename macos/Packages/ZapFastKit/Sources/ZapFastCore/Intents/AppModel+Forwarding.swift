/// Selecting messages, and forwarding, copying or sharing what was selected.
///
/// Part of `AppModel`, in a file of its own so that one file is one
/// subject; the state these read and write lives on the class.

import Foundation
import ZapFastBridge

extension AppModel {
    // MARK: Intents: selecting messages

    /// Upstream's `add_range` leaves out what cannot be acted on.
    public func canSelect(_ message: MessageRecord) -> Bool {
        switch message.content {
        case .revoked, .phoneOnly, .unsupported: false
        default: true
        }
    }

    public func isSelected(_ message: MessageRecord) -> Bool {
        selection?.chat == message.chat && selection?.ids.contains(message.id) == true
    }

    /// Starts selecting with this message ("Select", or ⌘-click).
    public func select(_ message: MessageRecord) {
        guard canSelect(message) else { return }
        if selection?.chat == message.chat {
            toggleSelected(message)
        } else {
            selection = MessageSelection(chat: message.chat, ids: [message.id], anchor: message.id)
        }
    }

    /// A click while selecting: in or out. Ids stay in chat order, so a
    /// forward arrives as it was sent; the last one out ends selecting.
    public func toggleSelected(_ message: MessageRecord) {
        guard var current = selection, current.chat == message.chat, canSelect(message) else { return }
        if current.ids.contains(message.id) {
            current.ids.removeAll { $0 == message.id }
        } else {
            current.ids.append(message.id)
        }
        current.anchor = message.id
        current.ids = inChatOrder(current.ids, chat: message.chat)
        selection = current.ids.isEmpty ? nil : current
    }

    /// A Shift-click while selecting: everything from the last click to
    /// this one joins.
    public func selectRange(to message: MessageRecord) {
        guard var current = selection, current.chat == message.chat else { return select(message) }
        let messages = conversations.conversation(message.chat).messages
        guard let from = messages.firstIndex(where: { $0.id == current.anchor }),
              let to = messages.firstIndex(where: { $0.id == message.id }) else { return toggleSelected(message) }
        let range = messages[min(from, to)...max(from, to)].filter(canSelect).map(\.id)
        current.ids = inChatOrder(Array(Set(current.ids).union(range)), chat: message.chat)
        current.anchor = message.id
        selection = current
    }

    /// A drag across messages begins on `message`, which the press has just
    /// picked or put back. The drag does what the press did: it picks what it
    /// passes over, or, when the press took the message out, takes those out
    /// too. Nil when nothing is picked.
    public func beginSweep(from message: MessageRecord) -> MessageSweep? {
        guard let current = selection, current.chat == message.chat else { return nil }
        return MessageSweep(
            chat: message.chat, anchor: message.id, base: Set(current.ids), adds: current.ids.contains(message.id)
        )
    }

    /// The drag is over `message`: everything from where it began to here
    /// is picked (or put back), and what an earlier reach picked beyond is
    /// as it was.
    public func sweep(_ sweep: MessageSweep, to message: MessageRecord) {
        guard sweep.chat == message.chat else { return }
        let messages = conversations.conversation(sweep.chat).messages
        guard let from = messages.firstIndex(where: { $0.id == sweep.anchor }),
              let to = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let covered = Set(messages[min(from, to)...max(from, to)].filter(canSelect).map(\.id))
        let ids = inChatOrder(Array(sweep.adds ? sweep.base.union(covered) : sweep.base.subtracting(covered)), chat: sweep.chat)
        guard selection?.ids != ids else { return }
        selection = ids.isEmpty ? nil : MessageSelection(chat: sweep.chat, ids: ids, anchor: sweep.anchor)
    }

    public func cancelSelection() {
        selection = nil
    }

    /// The selected messages that can be forwarded, oldest first.
    public var forwardableSelection: [String] {
        guard let selection else { return [] }
        let conversation = conversations.conversation(selection.chat)
        return selection.ids.filter { id in conversation.message(id).map(canForward) ?? false }
    }

    public func forwardSelection() {
        guard let chat = selection?.chat else { return }
        let ids = forwardableSelection
        guard !ids.isEmpty else { return }
        selection = nil
        forwarding = ForwardRequest(chat: chat, messages: ids)
    }

    /// Deletes the selected messages here, after the person confirmed.
    public func deleteSelectionForMe() {
        guard let selection else { return }
        self.selection = nil
        for id in selection.ids {
            backend.send(.deleteLocal(chat: selection.chat, id: id))
        }
    }

    /// The selected messages, in chat order.
    private var selectedMessages: [MessageRecord] {
        guard let selection else { return [] }
        let conversation = conversations.conversation(selection.chat)
        return inChatOrder(selection.ids, chat: selection.chat).compactMap(conversation.message)
    }

    /// Copies the selection as the phone does, with who wrote each message
    /// and when once there are several; selecting ends.
    public func copySelection(to write: (String) -> Void) {
        let messages = selectedMessages
        guard !messages.isEmpty else { return }
        write(transcript(of: messages))
        selection = nil
        post(.info, messages.count == 1
            ? String(localized: "Copied")
            : String(localized: "Copied \(messages.count) messages"))
    }

    /// What Share hands on: the selection's downloaded files, and the
    /// messages without a file as text. Files not downloaded are left out.
    public var shareableSelection: SelectionShare {
        let messages = selectedMessages
        let files = messages.compactMap(\.mediaURL)
        let texts = messages.filter { $0.content.media == nil }
        return SelectionShare(text: texts.isEmpty ? nil : transcript(of: texts), files: files)
    }

    private func transcript(of messages: [MessageRecord]) -> String {
        MessageTranscript.text(
            messages,
            name: { message in
                message.fromMe
                    ? session.account?.name.nonEmpty ?? String(localized: "You")
                    : chats.personName(message.sender, hint: message.senderName)
            },
            mentionName: { chats.displayName($0) }
        )
    }

    private func inChatOrder(_ ids: [String], chat: String) -> [String] {
        let wanted = Set(ids)
        return conversations.conversation(chat).messages.map(\.id).filter(wanted.contains)
    }

    // MARK: Intents: forwarding

    /// Upstream's rule: revoked, unsupported, phone-only, poll and
    /// interactive messages do not forward.
    public func canForward(_ message: MessageRecord) -> Bool {
        switch message.content {
        case .revoked, .unsupported, .phoneOnly, .poll, .interactive: false
        default: true
        }
    }

    public func forward(_ message: MessageRecord) {
        guard canForward(message) else { return }
        forwarding = ForwardRequest(chat: message.chat, messages: [message.id])
    }

    /// Sends the waiting messages to each of `targets` in turn, oldest
    /// first as upstream does. A `note` follows them into every chat once
    /// they have left, as the phone's "Add a message" does.
    public func forward(to targets: [String], note: String = "") {
        guard let request = forwarding, !targets.isEmpty else { return }
        forwarding = nil
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let since = Int64(Date.now.timeIntervalSince1970) - Self.forwardClockSlack
        for chat in targets {
            backend.send(.forward(fromChat: request.chat, messages: request.messages, toChat: chat))
            followSentChat()
            if !note.isEmpty {
                let pending = ForwardNote(chat: chat, text: note, expected: request.messages.count, since: since)
                forwardNotes.append(pending)
                expireForwardNote(pending.id, after: Self.forwardNoteWait)
            }
        }
        if targets.count == 1, let chat = targets.first {
            post(.info, String(localized: "Forwarded to \(forwardTargetName(chat))"))
        } else {
            post(.info, String(localized: "Forwarded to \(targets.count) chats"))
        }
    }

    public func forward(to chat: String) {
        forward(to: [chat])
    }

    /// A forward target's name, "You" for our own chat even before it exists.
    public func forwardTargetName(_ chat: String) -> String {
        if session.isOurs(chat) { return chats.selfTitle }
        return chats.chat(chat).map(chats.title(for:)) ?? chats.displayName(chat)
    }

    /// The chat of our own number, first in the forward sheet as on the
    /// phone, when the search allows it.
    public func forwardSelfTarget(query: String) -> String? {
        chats.offersSelf(query: query) ? session.account?.id : nil
    }

    /// The row timestamps come from the worker's clock, the same machine's,
    /// but a second may turn between the two reads.
    static let forwardClockSlack: Int64 = 2
    /// Long enough for a long queue of forwards; a note whose forwards never
    /// arrived goes back to that chat's composer instead of out alone.
    static let forwardNoteWait: Duration = .seconds(60)

    /// Watches our forwarded messages leave; a note goes once its chat's are out.
    func followForwards(_ messages: [MessageRecord]) {
        guard !forwardNotes.isEmpty else { return }
        for message in messages where message.fromMe && message.forwarded {
            for index in forwardNotes.indices { forwardNotes[index].follow(message) }
        }
        let ready = forwardNotes.filter(\.isReady)
        forwardNotes.removeAll(where: \.isReady)
        for note in ready { sendForwardNote(note) }
    }

    private func expireForwardNote(_ id: UUID, after wait: Duration) {
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            self?.forwardNoteExpired(id)
        }
    }

    /// Time is up: a note whose forwards were seen goes anyway (some may have
    /// failed); one whose forwards never came waits in the chat's composer.
    func forwardNoteExpired(_ id: UUID) {
        guard let index = forwardNotes.firstIndex(where: { $0.id == id }) else { return }
        let note = forwardNotes.remove(at: index)
        if note.sawForwards {
            sendForwardNote(note)
        } else {
            if (composerText[note.chat] ?? "").isEmpty { composerText[note.chat] = note.text }
            post(.error, String(localized: "Couldn't forward to \(forwardTargetName(note.chat)). Your message is in its composer."))
        }
    }

    private func sendForwardNote(_ note: ForwardNote) {
        backend.send(.sendText(chat: note.chat, text: note.text, quoting: nil, mentions: []))
        followSentChat()
    }

    public func cancelForward() {
        forwarding = nil
    }
}
