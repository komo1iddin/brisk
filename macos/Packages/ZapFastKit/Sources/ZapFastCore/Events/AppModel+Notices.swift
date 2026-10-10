/// Desktop notifications, and the notices shown inside the window
/// (upstream's `maybe_notify`).
///
/// Part of `AppModel`, in a file of its own so that one file is one
/// subject; the state these read and write lives on the class.

import Foundation
import ZapFastBridge

extension AppModel {
    // MARK: Notifications (upstream's `maybe_notify`)

    func maybeNotify(chat id: String, message: MessageRecord) {
        guard accountPreferences.notifications, !message.fromMe, let chat = chats.chat(id) else { return }
        let now = Int64(Date.now.timeIntervalSince1970)
        guard !chat.archived, chat.unread > 0, !chats.isMuted(chat), !chat.locked,
              now - message.timestamp <= 60 else { return }
        let reading = isReading && isOpen(id)
        guard !reading else { return }

        // A locked app says nothing about who wrote or what.
        let isGroup = chat.kind == .group
        // A locked app's chat or mention sound would tell who wrote, so only
        // the message sound plays, as upstream's `notify_while_locked` does.
        guard preferences.notificationPreviews, !appLock.isLocked else {
            let sound = notificationSound(chat: nil, forUs: false, isGroup: isGroup, preferences: preferences)
            notifier?.post(chat: id, message: message.id, title: "ZapFast",
                           body: String(localized: "New message"), picture: nil,
                           sound: SoundPlayer.shared.notificationSound(for: sound))
            return
        }
        let sound = notificationSound(
            chat: chat.notificationSound, forUs: isGroup && addressesUs(message), isGroup: isGroup,
            preferences: preferences
        )
        let title = chats.title(for: chat)
        let text = messageText(message)
        let body = chat.kind == .group
            ? "\(chats.displayName(message.sender, hint: message.senderName)): \(text)"
            : text
        let picture = avatars.url(for: id) ?? avatars.url(for: message.sender)
        notifier?.post(chat: id, message: message.id, title: title, body: body, picture: picture,
                       sound: SoundPlayer.shared.notificationSound(for: sound))
    }

    /// Upstream's `addresses_us`: a mention of one of our ids, or a reply
    /// to one of our messages.
    func addressesUs(_ message: MessageRecord) -> Bool {
        let ours = ourIDs
        let mentioned = message.mentions.contains { mention in
            ours.contains(mention.id) || ours.contains { $0.split(separator: "@").first.map(String.init) == mention.user }
        }
        return mentioned || message.quoted.map { ours.contains($0.sender) } == true
    }

    /// A chat's own notification sound, or nil to follow Settings.
    public func setChatSound(_ sound: NotificationSoundInfo?, chat: String) {
        backend.send(.setChatSound(chat: chat, sound: sound))
    }

    /// A message's summary with `@number` mention tokens shown as names.
    public func messageText(_ message: MessageRecord) -> String {
        message.mentions.reduce(message.summary) { text, mention in
            text.replacingOccurrences(of: "@\(mention.user)", with: "@\(chats.displayName(mention.id))")
        }
    }

    func handle(_ response: Notifier.Response) {
        switch response {
        case let .open(chat, message):
            let key = MessageKey(chat: chat, message: message)
            if appLock.isLocked {
                // The announced message waits for the unlock, as upstream's does.
                openAfterUnlock = key
            } else {
                open(notified: key)
            }
            bringToFront()
        case let .reply(chat, message, text):
            guard !appLock.isLocked else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            backend.send(.sendText(chat: chat, text: trimmed, quoting: message, mentions: []))
            followSentChat()
            markRead(chat)
        case .markRead(let chat):
            guard !appLock.isLocked else { return }
            markRead(chat)
        }
    }

    /// A clicked notification lands on the message it announced, loading
    /// the history up to it when needed.
    func open(notified key: MessageKey) {
        if key.message.isEmpty {
            selectedChatID = key.chat
        } else {
            reveal(key)
        }
    }

    func post(_ kind: Notice.Kind, _ text: String) {
        notices.append(Notice(kind: kind, text: text))
        if notices.count > 3 { notices.removeFirst(notices.count - 3) }
    }
}
