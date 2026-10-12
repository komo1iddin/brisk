/// Applying what the backend reports: every `BridgeEvent` lands here and
/// becomes state the views read.
///
/// Part of `AppModel`, in a file of its own so that one file is one
/// subject; the state these read and write lives on the class.

import Foundation
import ZapFastBridge

extension AppModel {
    // MARK: Events

    func apply(_ events: [BridgeEvent]) {
        for event in events {
            eventStats.measure(event) { apply(event) }
        }
    }

    func apply(_ event: BridgeEvent) {
        applyTimelineEvent(event)
        switch event {
        case let .messageWindow(chat, request, messages, hasOlder, hasNewer, error):
            applyWindow(chat: chat, request: request, messages: messages, hasOlder: hasOlder, hasNewer: hasNewer, error: error)
        case .link(let state):
            applyLink(state)
        case let .me(id, lid, name, about):
            session.account = .init(id: id, lid: lid, name: name, about: about)
        case .chats(let list):
            chats.replaceAll(list)
            restoreLastChat()
            launch.step("chat list from the archive")
        case .chatUpdated(let chat):
            chats.upsert(chat)
            // A chat locked on the phone leaves the window unless the
            // folder is open here.
            if chat.locked, chat.id == selectedChatID, !lockedChats.isOpen { selectedChatID = nil }
            if !chat.looksUnread { notifier?.clear(chat: chat.id) }
            // An open chat that turns unread was read by the person looking at it.
            if isOpen(chat.id), chat.looksUnread, !chat.markedUnread, !appLock.isLocked {
                markRead(chat.id)
            }
        case .chatRemoved(let chat):
            defaultWindowRequests[chat] = nil
            // The composer goes first, so closing the chat saves no draft for it.
            forgetComposer(of: chat)
            keptUnread.remove(chat)
            chats.remove(chat)
            conversations.forget(chat)
            if selectedChatID == chat { selectedChatID = nil }
            search.dropHits(in: chat, through: .max)
            if chatConfirmation?.chat == chat { chatConfirmation = nil }
            notifier?.clear(chat: chat)
        case let .chatCleared(chat, through):
            defaultWindowRequests[chat] = nil
            applyCleared(chat, through: through)
        case .drafts(let drafts):
            chats.replaceDrafts(drafts)
        case let .messages(chat, messages, older, complete):
            let bare = conversations.applyMessages(
                chat: chat, messages: messages, older: older, complete: complete
            )
            if bare, isOpen(chat) { loadOlder(in: chat) }
            if unreadDivider?.chat == chat { resolveUnreadDivider() }
            if pendingJump?.chat == chat { continueJump() }
            if !older { followForwards(messages) }
            if older, phoneFetch?.chat == chat { phoneFetch?.olderArrived(count: messages.count) }
        case .messageUpdated(let message):
            if selection?.chat == message.chat, selectionMetadata[message.id] != nil {
                selectionMetadata[message.id] = SelectionMetadata(order: message.order, forwardable: canForward(message))
            }
            conversations.applyUpdated(message)
            followForwards([message])
        case let .messageDeleted(chat, id):
            conversations.applyDeleted(chat: chat, id: id)
        case let .incoming(chat, message):
            maybeNotify(chat: chat, message: message)
        case .contacts(let contacts):
            chats.replaceContacts(contacts)
        case let .searchHits(query, messages):
            let visible = messages.filter { chats.chat($0.chat)?.locked != true }
            search.applyMessageHits(query: query, messages: visible, wanted: wantedMessageQuery)
        case .chatHits:
            // Upstream's single-query search; the bar asks with `searchChat`.
            break
        case let .chatSearchHits(chat, request, ids, messages, truncated):
            search.applyChatSearchHits(chat: chat, request: request, ids: ids, messages: messages, truncated: truncated)
        case let .chatDays(chat, starts, first):
            search.applyDays(chat: chat, starts: starts, first: first)
        case .labels(let labels):
            chats.replaceLabels(labels)
        case .stickers(let library):
            stickers.apply(library)
        case let .stickerPackPreview(pack, publisher, error):
            guard stickerPackPreview != nil else { break }
            if let pack {
                stickerPackPreview?.state = .ready(pack: pack, publisher: publisher ?? "")
            } else {
                stickerPackPreview?.state = .failed(error ?? String(localized: "This sticker pack could not be opened."))
            }
        case let .gifs(query, gifs, error):
            stickers.applyGifs(query: query, gifs: gifs, error: error, wanted: wantedGifQuery ?? "")
        case let .invitePreview(code, info, error):
            guard var current = invite, current.code == code else { break }
            current.state = info.map { .ready($0) } ?? .failed(error ?? String(localized: "Could not read this invite."))
            invite = current
        case let .inviteJoined(code, chat, pending, error):
            guard var current = invite, current.code == code else { break }
            if let chat {
                invite = nil
                if pending {
                    post(.info, String(localized: "Request sent. An admin must approve it before you join."))
                } else {
                    selectedChatID = chat
                }
            } else {
                current.state = .failed(error ?? String(localized: "Could not join this group."))
                invite = current
            }
        case let .contactReady(id, name):
            newContactPending = false
            startChat(with: id, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? PhoneFormat.display(id: id))
        case let .groupSaving(chat, saving):
            if saving { groupSaving.insert(chat) } else { groupSaving.remove(chat) }
        case let .interactiveReplyState(chat, message, pending):
            let key = MessageKey(chat: chat, message: message)
            if pending { interactiveSending.insert(key) } else { interactiveSending.remove(key) }
        case let .pollCreated(chat, error):
            pollCreating = false
            if let error {
                post(.error, error)
            } else if pollComposerChat == chat {
                pollComposerChat = nil
            }
        case let .pollVoted(chat, message, error):
            pollVoting.remove(MessageKey(chat: chat, message: message))
            if let error { post(.error, error) }
        case let .typing(chat, sender, composing):
            conversations.applyTyping(chat: chat, sender: sender, composing: composing)
        case let .presence(id, online, lastSeen):
            conversations.applyPresence(id: id, online: online, lastSeen: lastSeen)
        case let .avatar(id, full, path):
            avatars.apply(id: id, full: full, path: path)
        case let .media(chat, message, card, path, error):
            conversations.applyMedia(chat: chat, message: message, card: card.map(Int.init), path: path, error: error)
            let key = MessageKey(chat: chat, message: message)
            if card == nil, phoneFetch?.chat == chat { phoneFetch?.fileFinished(message: message, error: error) }
            if card == nil, askedDownloads.remove(key) != nil, let error {
                post(.error, String(localized: "Couldn't download: \(DownloadFailure(error).explanation)"))
            }
            if videoWanted == key {
                videoWanted = nil
                if path != nil, error == nil, isOpen(chat), !appLock.isLocked,
                   let record = loadedMessage(chat: chat, id: message) {
                    playVideo(record)
                }
            }
        case .syncing(let active):
            session.isSyncing = active
            if !active { session.syncProgress = nil }
        case .syncProgress(let percent):
            session.syncProgress = percent
        case let .olderFetched(chat, more):
            conversations.applyOlderFetched(chat: chat, more: more)
            phoneHistory.answered(chat, more: more, holding: conversations.conversation(chat).messages.count)
            if phoneFetch?.chat == chat { phoneFetch?.olderAnswered(more: more) }
        case .receiptsPrivacy(let disabled):
            session.receiptsDisabled = disabled
        case .pinLimit(let limit):
            session.pinLimit = limit
        case let .accountPrivacy(values, failed):
            privacy.snapshot.applyFetch(values: values, failed: failed)
            privacy.changed()
            followReceiptsPrivacy()
        case .accountPrivacySaved(let kind):
            // A confirmation nothing waits for belongs to an earlier link.
            if privacy.snapshot.finishSet(kind: kind), kind == .readReceipts { followReceiptsPrivacy() }
            privacy.changed()
        case .accountPrivacyFailed(let kind):
            privacy.snapshot.failSet(kind: kind)
            privacy.changed()
            post(.error, String(localized: "Your phone didn't accept the privacy change."))
        case .receipts(let receipts):
            guard let watched = receiptsWatch, watched.chat == receipts.chat,
                  watched.message == receipts.message else { break }
            self.receipts = receipts
        case let .sendRefused(chat, quoting, reason, text, files, image, caption, voice):
            // What was refused comes back to the composer, as upstream does.
            if let restored = text ?? caption, (composerText[chat] ?? "").isEmpty {
                composerText[chat] = restored
            }
            if !voice.isEmpty { unsentVoice = UnsentVoice(chat: chat, samples: voice) }
            // So does the reply, which must be cancelled to send a voice
            // message whose quote is gone.
            if let quoting, replyingTo[chat] == nil, let message = loadedMessage(chat: chat, id: quoting) {
                replyingTo[chat] = message
            }
            if chat == selectedChatID {
                let returned = files.map { Attachment(.file(URL(filePath: $0))) }
                    + (image.map { [Attachment(.image($0))] } ?? [])
                // Photos among them reopen the editor, the caption with them.
                if !returned.isEmpty { stage(returned, in: chat) }
            }
            post(.error, reason == .offline
                ? String(localized: "Not sent: you are offline.")
                : String(localized: "Not sent: the quoted message is unavailable."))
        case .info(let message):
            post(.info, message)
        case .error(let message):
            // A number WhatsApp does not know ends its check with an error.
            newContactPending = false
            post(.error, message)
        case .accountRemoved:
            onAccountRemoved()
        case .notBridged(let name):
            log.debug("event not bridged yet: \(name, privacy: .public)")
        }
    }

    /// Upstream's `handle_chat_cleared`: nothing up to `through` is left
    /// here or on the phone, so the chat pages no further, and whatever
    /// pointed at one of its messages lets go.
    private func applyCleared(_ chat: String, through: Int64) {
        // A confirmation still open would clear what arrived since.
        if chatConfirmation?.chat == chat { chatConfirmation = nil }
        conversations.applyCleared(chat: chat, through: through)
        notifier?.clear(chat: chat)
        chats.setDraft("", for: chat)
        if chat != selectedChatID { forgetComposer(of: chat) }
        search.dropHits(in: chat, through: through)
        let remaining = conversations.conversation(chat)
        if let message = editing[chat], remaining.message(message.id) == nil {
            editing[chat] = nil
            textBeforeEdit[chat] = nil
            mentionsBeforeEdit[chat] = nil
            composerText[chat] = ""
            composerMentions[chat] = nil
        }
        if let message = replyingTo[chat], remaining.message(message.id) == nil {
            replyingTo[chat] = nil
        }
        if let key = messageInfo, key.chat == chat, remaining.message(key.message) == nil {
            messageInfo = nil
        }
    }

    /// Everything the composer kept for a chat that is gone.
    private func forgetComposer(of chat: String) {
        composerText[chat] = nil
        composerMentions[chat] = nil
        attachments[chat] = nil
        replyingTo[chat] = nil
        editing[chat] = nil
        textBeforeEdit[chat] = nil
        mentionsBeforeEdit[chat] = nil
        if unsentVoice?.chat == chat { unsentVoice = nil }
    }

    private func applyLink(_ state: LinkState) {
        let wasDisconnected = if case .disconnected = session.link { true } else { false }
        switch state {
        case .connected:
            launch.step("connected to WhatsApp")
            if wasDisconnected { post(.info, String(localized: "Back online")) }
            avatars.forgetMisses()
            if let selectedChatID { ensureLoaded(selectedChatID) }
        case .loggedOut:
            calls.reset()
            chats.clear()
            conversations.clear()
            defaultWindowRequests.removeAll()
            for reader in timelineReaders.values {
                reader.pending = nil
                reader.store.clear()
            }
            phoneHistory.clear()
            goneMedia.clear()
            search.clear()
            stickers.clear()
            avatars.clear()
            composerText = [:]
            composerMentions = [:]
            attachments = [:]
            replyingTo = [:]
            editing = [:]
            textBeforeEdit = [:]
            mentionsBeforeEdit = [:]
            forwarding = nil
            forwardNotes = []
            invite = nil
            stickerPackPreview = nil
            pollVoting = []
            interactiveSending = []
            privacy.snapshot.reset()
            privacy.changed()
            interactiveList = nil
            pollComposerChat = nil
            pollCreating = false
            groupSaving = []
            pollResults = nil
            pollRefreshAsked = []
            phoneFetchShown = false
            phoneFetch = nil
            chatConfirmation = nil
            messageInfo = nil
            receipts = nil
            receiptsWatch = nil
            notifier?.clearAll()
            video.stop()
            selectedChatID = nil
            openAfterUnlock = nil
            closeLockedChats()
            // Unlinking is how a forgotten app-lock password is recovered,
            // once no account here is linked: the lock guards them all.
            if !(hub?.models.contains { $0 !== self && $0.isLinked } ?? false) { appLock.forget() }
            post(.error, String(localized: "This device was unlinked from your phone"))
        case .failed(let message):
            post(.error, message)
        case .starting, .unlinked, .connecting, .disconnected:
            break
        }
        session.link = state
        if case .connected = state {
            phoneFetch?.linkConnected()
            hub?.linked(accountID)
        }
    }
}
