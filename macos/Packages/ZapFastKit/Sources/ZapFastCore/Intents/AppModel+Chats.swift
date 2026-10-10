/// The chat list, and what opening, closing, locking or deleting a chat does.
///
/// Part of `AppModel`, in a file of its own so that one file is one
/// subject; the state these read and write lives on the class.

import Foundation
import ZapFastBridge

extension AppModel {
    // MARK: Intents: chat windows

    /// The chat shows in the main window or one of its own.
    public func isOpen(_ chat: String) -> Bool {
        selectedChatID == chat || windowChats[chat, default: 0] > 0
    }

    /// A window of its own now shows `chat`: loaded, and read as the main
    /// window's chat is when opened.
    public func chatWindowAppeared(_ chat: String) {
        windowChats[chat, default: 0] += 1
        if composerText[chat] == nil, let draft = chats.drafts[chat] {
            composerText[chat] = draft
        }
        ensureLoaded(chat)
        if chats.chat(chat)?.looksUnread == true, !appLock.isLocked { markRead(chat) }
        notifier?.clear(chat: chat)
    }

    public func chatWindowDisappeared(_ chat: String) {
        let left = windowChats[chat, default: 1] - 1
        windowChats[chat] = left > 0 ? left : nil
        guard !isOpen(chat) else { return }
        flushDraft(for: chat)
        if infoChat == chat { closeInfo() }
        if search.chat?.chat == chat { closeChatSearch() }
        if let playing = voice.current?.chat, playing == chat { voice.stop() }
        if let playing = video.current?.chat, playing == chat { video.stop() }
    }

    public func messageYourself() {
        guard let me = session.account?.id else { return }
        newChatShown = false
        startChat(with: me)
    }

    /// Checks a number with WhatsApp and opens its chat once it answers,
    /// saving a name for it when one is given.
    public func newContact(phone: String, first: String, last: String) {
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty, !newContactPending else { return }
        let name = ContactName.compose(first: first, last: last)
        newContactPending = true
        backend.send(.newContact(
            phone: digits, fullName: name?.full, firstName: name?.short,
            toPhone: accountPreferences.saveContactsToPhone
        ))
    }

    // MARK: Intents: chat list

    public func setPinned(_ pinned: Bool, chat: String) {
        backend.send(.setPinned(chat: chat, pinned: pinned))
    }

    public func setArchived(_ archived: Bool, chat: String) {
        backend.send(.setArchived(chat: chat, archived: archived))
    }

    public func setFavorite(_ favorite: Bool, chat: String) {
        backend.send(.setFavorite(chat: chat, favorite: favorite))
    }

    /// `until` in Unix seconds, 0 for always, nil to unmute.
    public func setMuted(until: Int64?, chat: String) {
        backend.send(.setMuted(chat: chat, until: until))
    }

    public func markRead(_ chat: String) {
        backend.send(.markRead(chat: chat, receipts: accountPreferences.sendReadReceipts))
    }

    public func markUnread(_ chat: String) {
        backend.send(.markUnread(chat: chat))
    }

    // MARK: Intents: clearing and deleting chats

    /// Both reach the phone first, so they wait for a connection.
    public var canClearOrDeleteChats: Bool {
        session.isConnected
    }

    public func confirmClear(_ chat: String) {
        guard canClearOrDeleteChats else { return }
        chatConfirmation = ChatConfirmation(chat: chat, action: .clear)
    }

    public func confirmDelete(_ chat: String) {
        guard canClearOrDeleteChats else { return }
        chatConfirmation = ChatConfirmation(chat: chat, action: .delete)
    }

    /// The person confirmed. The phone is asked first; the messages or the
    /// chat go here once it agreed (`chatCleared`, `chatRemoved`).
    public func perform(_ confirmation: ChatConfirmation) {
        chatConfirmation = nil
        switch confirmation.action {
        case .clear where canClearOrDeleteChats: backend.send(.clearChat(chat: confirmation.chat))
        case .delete where canClearOrDeleteChats: backend.send(.deleteChat(chat: confirmation.chat))
        case .lock: setLocked(true, chat: confirmation.chat)
        case .leave: if let chat = chats.chat(confirmation.chat) { leaveGroup(chat, archive: false) }
        case .clear, .delete: break
        }
    }

    /// Asks before leaving a group or channel, from its row's menu.
    public func confirmLeave(_ chat: String) {
        chatConfirmation = ChatConfirmation(chat: chat, action: .leave)
    }

    // MARK: Intents: locked chats

    /// The Locked folder: straight in when this session opened it, else
    /// the code sheet (which sets a code up when there is none).
    public func openLockedChats() {
        guard !lockedChats.isOpen else { return }
        lockedChats.resetAttempt()
        lockedChatsPrompt = true
    }

    /// Leaving the folder locks it again, and a locked chat left open closes.
    public func closeLockedChats() {
        lockedChatsPrompt = false
        lockedChats.close()
        if let selectedChatID, chats.chat(selectedChatID)?.locked == true {
            self.selectedChatID = nil
        }
    }

    /// The code sheet opened the folder.
    public func lockedChatsOpened() {
        lockedChatsPrompt = false
        // A chat open from the normal list stays open inside the folder only
        // if it is locked; anything else would be out of place there.
        if let selectedChatID, chats.chat(selectedChatID)?.locked != true {
            self.selectedChatID = nil
        }
    }

    /// Asks before locking, since the chat leaves the list and the lock
    /// syncs to the phone. Unlocking needs no confirmation.
    public func confirmLock(_ chat: String) {
        chatConfirmation = ChatConfirmation(chat: chat, action: .lock)
    }

    /// Upstream's `SetLocked`: the phone learns it through app state.
    /// Locking the open chat closes it, as the phone does; the first lock
    /// asks for a local code.
    public func setLocked(_ locked: Bool, chat: String) {
        backend.send(.setLocked(chat: chat, locked: locked))
        guard locked else { return }
        if selectedChatID == chat, !lockedChats.isOpen { selectedChatID = nil }
        if !lockedChats.hasCode { openLockedChats() }
    }

    // MARK: Opening a chat

    func opened(_ chat: String) {
        if composerText[chat] == nil, let draft = chats.drafts[chat] {
            composerText[chat] = draft
        }
        // Counted before the chat is marked read, as upstream does.
        let unread = chats.chat(chat)?.unread ?? 0
        unreadDivider = unread > 0 ? UnreadDivider(chat: chat, count: unread) : nil
        resolveUnreadDivider()
        ensureLoaded(chat)
        if chats.chat(chat)?.looksUnread == true, !appLock.isLocked {
            markRead(chat)
        }
    }

    /// Pins the divider to the first unread message once the chat's
    /// messages are here, so later arrivals do not move it. The first
    /// unread message is the count-th incoming one from the end; a count
    /// reaching past the loaded page shows no divider.
    func resolveUnreadDivider() {
        guard let divider = unreadDivider, divider.message == nil else { return }
        let messages = conversations.conversation(divider.chat).messages
        guard !messages.isEmpty else { return }
        let first = messages.reversed().filter { !$0.fromMe }.dropFirst(Int(divider.count) - 1).first
        if let first {
            unreadDivider?.message = first.id
        } else {
            unreadDivider = nil
        }
    }

    func ensureLoaded(_ chat: String) {
        guard !conversations.conversation(chat).requested else { return }
        conversations.markRequested(chat)
        backend.send(.loadChat(chat: chat, before: nil))
    }

    func flushDraft(for chat: String) {
        let text = composerText[chat] ?? ""
        guard text != (chats.drafts[chat] ?? "") else { return }
        chats.setDraft(text, for: chat)
        backend.send(.saveDraft(chat: chat, text: text))
        stopComposing(in: chat)
    }
}
