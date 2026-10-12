/// Asking the phone for older history, repairing gaps in it, and what a
/// message's info panel reports.
///
/// Part of `AppModel`, in a file of its own so that one file is one
/// subject; the state these read and write lives on the class.

import Foundation
import ZapFastBridge

extension AppModel {
    // MARK: Intents: fetching from the phone

    /// Opens the sheet for getting a chat's files and older messages from the
    /// phone. A job already under way stays the one shown.
    public func openPhoneFetch(_ chat: String) {
        if let current = phoneFetch, current.isRunning || current.chat == chat {
            phoneFetchShown = true
            return
        }
        let fetch = PhoneFetch(chat: chat, hooks: .init(
            openReader: { [backend] in try await backend.openChatReader() },
            download: { [weak self] message in self?.fetchDownload(chat: chat, message: message) },
            askOlder: { [weak self] in self?.fetchOlder(chat: chat) },
            isConnected: { [weak self] in self?.session.isConnected ?? false },
            finished: { [weak self] summary in
                guard let self else { return }
                log.info("fetch finished: \(summary, privacy: .public)")
                guard !phoneFetchShown else { return }
                post(.info, summary)
            },
            gone: goneMedia
        ))
        phoneFetch = fetch
        phoneFetchShown = true
    }

    #if DEBUG
    /// Reconnects without waiting, as the network coming back does.
    public func debugReconnectNow() -> Bool {
        backend.reconnectNow()
    }
    #endif

    /// Hides the sheet. A job that runs keeps going; any other is forgotten.
    public func closePhoneFetch() {
        phoneFetchShown = false
        if phoneFetch?.isRunning != true { phoneFetch = nil }
    }

    /// One download of the fetch job: a file the person did not scroll to.
    private func fetchDownload(chat: String, message: String) {
        conversations.startDownload(MessageKey(chat: chat, message: message))
        backend.send(.download(chat: chat, message: message, card: nil))
    }

    /// One request for older messages of the fetch job.
    func fetchOlder(chat: String) {
        phoneHistory.asking(chat, holding: conversations.conversation(chat).messages.count)
        backend.send(.fetchOlder(chat: chat))
    }

    // MARK: Intents: history repair

    /// Upstream's "Reload earlier messages": while linked, for a message
    /// WhatsApp has.
    public func canReloadHistory(_ message: MessageRecord) -> Bool {
        session.isConnected && message.status != .pending && message.status != .failed
    }

    /// Asks the phone again for the messages just before `message`, which
    /// fills a gap or fixes the order inside history already here. It is
    /// asked even when the phone said the chat has nothing older.
    public func reloadHistory(before message: MessageRecord) {
        guard canReloadHistory(message) else { return }
        let conversation = conversations.conversation(message.chat)
        guard loadedMessage(chat: message.chat, id: message.id) != nil else { return }
        guard !conversation.fetchingPhone else {
            post(.info, String(localized: "History is already being requested for this chat"))
            return
        }
        conversations.markFetchingPhone(message.chat)
        for reader in timelineReaders.values where reader.chat == message.chat
            && reader.store.loadedMessage(chat: message.chat, id: message.id) != nil {
            reader.store.markFetchingPhone(message.chat)
        }
        phoneHistory.asking(message.chat, holding: conversation.messages.count)
        backend.send(.reloadHistory(chat: message.chat, message: message.id))
        post(.info, String(localized: "Requesting earlier messages from your phone"))
    }

    // MARK: Intents: message info

    /// Upstream offers "Message info" for our own messages that left this
    /// computer and were not deleted.
    public func canShowInfo(_ message: MessageRecord) -> Bool {
        guard message.fromMe else { return false }
        if case .revoked = message.content { return false }
        switch message.status {
        case .none, .pending, .failed: return false
        default: return true
        }
    }

    public func showInfo(_ message: MessageRecord) {
        guard canShowInfo(message) else { return }
        messageInfo = MessageKey(chat: message.chat, message: message.id)
    }

    /// Keeps the backend following receipts for exactly the group message
    /// whose info is open (upstream's `follow_receipts`); a direct
    /// message's times are on the message itself.
    func followReceipts() {
        let wanted = messageInfo.flatMap { chats.chat($0.chat)?.kind == .group ? $0 : nil }
        guard wanted != receiptsWatch else { return }
        receipts = nil
        receiptsWatch = wanted
        if let wanted {
            backend.send(.watchReceipts(chat: wanted.chat, message: wanted.message))
        } else {
            backend.send(.stopWatchingReceipts)
        }
    }
}
