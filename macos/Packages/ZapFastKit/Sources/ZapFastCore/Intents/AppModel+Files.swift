/// Downloading attachments, the download folder, the proxy, and exporting a chat.
///
/// Part of `AppModel`, in a file of its own so that one file is one
/// subject; the state these read and write lives on the class.

import Foundation
import ZapFastBridge

extension AppModel {
    // MARK: Intents: files and network

    /// Where downloads go now: the chosen folder, or the media cache.
    public var downloadFolderInUse: URL {
        preferences.downloadFolder.map { URL(filePath: $0) }
            ?? (backend as? LiveBackend)?.mediaFolder
            ?? paths.caches.appending(path: "accounts/\(accountID)/media")
    }

    /// New downloads go to `folder`, or back to the media cache with nil.
    /// Files already downloaded stay where they are.
    public func setDownloadFolder(_ folder: URL?) {
        let path = folder?.path(percentEncoded: false)
        guard path != preferences.downloadFolder else { return }
        preferences.downloadFolder = path
        sendToEveryAccount(.setDownloadFolder(path: path))
    }

    /// Whether archived chats stay archived when a message arrives or is sent.
    public func setKeepChatsArchived(_ keep: Bool) {
        guard keep != preferences.keepChatsArchived else { return }
        preferences.keepChatsArchived = keep
        sendToEveryAccount(.setKeepChatsArchived(keep: keep))
    }

    /// Uses a new proxy and reconnects through it, as upstream's SetProxy;
    /// returns why the address cannot be used instead, if it cannot.
    @discardableResult
    public func setProxy(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != preferences.proxy else { return nil }
        if let problem = proxyProblem(value: value) { return problem }
        preferences.proxy = value
        sendToEveryAccount(.setProxy(proxy: value))
        return nil
    }

    /// A setting of the whole app goes to every account's backend, as
    /// upstream sends the download folder and proxy to each.
    private func sendToEveryAccount(_ command: BridgeCommand) {
        for model in hub?.models ?? [self] { model.backend.send(command) }
    }

    func followSentChat() {
        sentChatFollows &+= 1
        lastSentHere = Date()
        SendSound.play(preferences.sendSound)
    }


    /// Sends one command to this account's backend, for the hub.
    func sendSetting(_ command: BridgeCommand) {
        backend.send(command)
    }

    /// Shows an error in this account's window.
    func report(error: String) {
        post(.error, error)
    }

    /// Forgets what is kept about a removed account outside its folders.
    func forgetAccount() {
        accountPreferences.forget()
        goneMedia.clear()
        notifier?.clearAll()
    }

    /// Opens the chat that was open when ZapFast last ran, once, when the
    /// chats first arrive; one since removed or locked is forgotten.
    func restoreLastChat() {
        guard !lastChatRestored else { return }
        lastChatRestored = true
        guard selectedChatID == nil, let id = accountPreferences.lastChat else { return }
        if let chat = chats.chat(id), !chat.locked {
            selectedChatID = id
        } else {
            accountPreferences.lastChat = nil
        }
    }

    /// Upstream's `remember_emoji`: the latest first, 36 kept.
    public func rememberEmoji(_ emoji: String) {
        var recent = preferences.recentEmoji.filter { $0 != emoji }
        recent.insert(emoji, at: 0)
        preferences.recentEmoji = Array(recent.prefix(36))
    }

    public func composerEdited(in chat: String) {
        guard accountPreferences.sendTyping else { return }
        if composingIn[chat] == nil {
            backend.send(.composing(chat: chat, composing: true))
        }
        composingIn[chat]?.cancel()
        composingIn[chat] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.stopComposing(in: chat)
        }
    }

    func stopComposing(in chat: String) {
        guard let task = composingIn.removeValue(forKey: chat) else { return }
        task.cancel()
        backend.send(.composing(chat: chat, composing: false))
    }

    public func download(_ message: MessageRecord, automatic: Bool = false) {
        let key = MessageKey(chat: message.chat, message: message.id)
        // A download the person asked for says why it failed; one that began
        // by itself, as a message scrolled into view, fails quietly.
        if !automatic { askedDownloads.insert(key) }
        guard conversations.download(key) != .downloading else { return }
        conversations.startDownload(key)
        backend.send(.download(chat: message.chat, message: message.id, card: nil))
    }

    // MARK: Intents: exporting a chat

    /// Asks how to export: the chat's media goes into a zip beside its text,
    /// or the text stands alone.
    public func requestExport(_ chat: String) {
        guard exportingChat == nil else { return }
        exportRequest = ChatExportRequest(chat: chat)
    }

    /// Writes the chat as a conversation to read (`ChatExport`), from what
    /// this Mac's archive holds, into a new folder inside `parent`.
    /// `finished` hears where it went, or why it did not.
    public func exportChat(
        _ chat: String,
        includeMedia: Bool,
        into parent: URL,
        finished: @escaping @MainActor (Result<ChatExportSummary, Error>) -> Void = { _ in }
    ) {
        exportRequest = nil
        guard exportingChat == nil else { return }
        exportingChat = chat
        post(.info, String(localized: "Exporting chat…"))
        let me = session.account?.name.nonEmpty ?? String(localized: "You")
        let chats = chats
        let title = chats.chat(chat).map(chats.title(for:)) ?? String(localized: "Chat")
        Task {
            do {
                let reader = try await backend.openChatReader()
                let entries = try await ChatExport.collect(
                    chat: chat,
                    reader: reader,
                    me: me,
                    name: { chats.personName($0.sender, hint: $0.senderName) },
                    quotedName: { chats.displayName($0.sender, hint: $0.senderName) },
                    mentionName: { chats.displayName($0) }
                )
                let written = try await ChatExportWriter.write(
                    entries, title: title, includeMedia: includeMedia, into: parent
                )
                exportingChat = nil
                post(.info, Self.exportedText(written))
                finished(.success(written))
            } catch {
                exportingChat = nil
                post(.error, String(localized: "The chat could not be exported: \(error.localizedDescription)"))
                finished(.failure(error))
            }
        }
    }

    private static func exportedText(_ summary: ChatExportSummary) -> String {
        let done = summary.messages == 1
            ? String(localized: "Exported 1 message")
            : String(localized: "Exported \(summary.messages) messages")
        guard summary.missingMedia > 0 else { return done }
        return done + ". " + String(localized: "Attachments that are not downloaded were left out.")
    }
}
