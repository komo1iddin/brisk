/// Writing in a chat: the composer, its mentions, and editing what was sent.
///
/// Part of `AppModel`, in a file of its own so that one file is one
/// subject; the state these read and write lives on the class.

import Foundation
import ZapFastBridge

extension AppModel {
    // MARK: Intents: conversation

    public func loadOlder(in chat: String) {
        let conversation = conversations.conversation(chat)
        guard !conversation.loadingOlder else { return }
        if !conversation.complete, let key = conversation.oldestKey {
            conversations.markLoadingOlder(chat)
            backend.send(.loadChat(chat: chat, before: key))
        } else if conversation.complete, !conversation.fetchingPhone, !conversation.phoneExhausted,
                  session.isConnected, phoneHistory.mayAsk(chat) {
            conversations.markFetchingPhone(chat)
            phoneHistory.asking(chat, holding: conversation.messages.count)
            backend.send(.fetchOlder(chat: chat))
        }
    }

    /// Sends what the composer holds: its attachments with the text as
    /// their caption, or the text alone.
    public func sendText(in chat: String) {
        let text = (composerText[chat] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if editing[chat] == nil, isEditingMedia(in: chat) {
            sendMedia(in: chat)
            return
        }
        if editing[chat] == nil, !(attachments[chat] ?? []).isEmpty {
            sendAttachments(in: chat, caption: text)
            return
        }
        guard !text.isEmpty else { return }
        if let message = editing[chat] {
            finishEditing(message, with: text)
            return
        }
        let (encoded, mentions) = encodeMentions(text, in: chat)
        let quoting = replyingTo.removeValue(forKey: chat)?.id
        composerText[chat] = ""
        chats.setDraft("", for: chat)
        backend.send(.saveDraft(chat: chat, text: ""))
        stopComposing(in: chat)
        backend.send(.sendText(chat: chat, text: encoded, quoting: quoting, mentions: mentions))
        followSentChat()
    }

    // MARK: Intents: mentions

    /// Group members matching what follows an `@` in the composer
    /// (upstream's `mention_candidates`): by name, or by digits of their
    /// number; never us, and only in groups.
    public func mentionCandidates(in chat: String, query: String) -> [MentionCandidate] {
        guard let summary = chats.chat(chat), summary.kind == .group else { return [] }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = query.filter { $0.isASCII && $0.isNumber }
        return chats.members(of: summary)
            .filter { member in
                guard !session.isOurs(member.id) else { return false }
                if needle.isEmpty { return true }
                return member.name.trimmingPrefix("~").lowercased().contains(needle)
                    || (!digits.isEmpty && (MentionEncoding.user(of: member.id)?.contains(digits) ?? false))
            }
            .map { MentionCandidate(id: $0.id, name: $0.name, phone: PhoneFormat.display(id: $0.id)) }
    }

    /// A member was picked; the composer now holds `@name` for them.
    public func addMention(_ candidate: MentionCandidate, in chat: String) {
        guard chats.chat(chat)?.participants.contains(candidate.id) == true else { return }
        composerMentions[chat, default: []].append(ComposerMention(id: candidate.id, name: candidate.name))
    }

    /// The composer's text with picked names as `@user` tokens, and whom
    /// it mentions. The picks are used up.
    func encodeMentions(_ text: String, in chat: String) -> (String, [String]) {
        let picked = composerMentions.removeValue(forKey: chat) ?? []
        let participants = chats.chat(chat)?.participants ?? []
        return MentionEncoding.encode(text, picked: picked, participants: participants)
    }

    public func reply(to message: MessageRecord) {
        // Replying while editing starts a new message: the edited text
        // must not go out as the reply.
        cancelEditing(in: message.chat)
        replyingTo[message.chat] = message
        composerFocusRequests += 1
    }

    // MARK: Intents: editing

    /// Upstream's `EDIT_WINDOW` and `REVOKE_WINDOW`, in seconds.
    public static let editWindow: Int64 = 15 * 60
    public static let revokeWindow: Int64 = 2 * 24 * 60 * 60

    /// Upstream's `can_edit`: our own text messages, for fifteen minutes.
    public func canEdit(_ message: MessageRecord, now: Date = .now) -> Bool {
        guard message.fromMe, case .text = message.content else { return false }
        return Int64(now.timeIntervalSince1970) - message.timestamp <= Self.editWindow
    }

    /// Upstream's `can_revoke`: our own messages, for two days.
    public func canRevoke(_ message: MessageRecord, now: Date = .now) -> Bool {
        guard message.fromMe else { return false }
        if case .revoked = message.content { return false }
        return Int64(now.timeIntervalSince1970) - message.timestamp <= Self.revokeWindow
    }

    /// Puts a message's text in the composer to be changed; what was being
    /// typed comes back when the edit ends.
    public func startEditing(_ message: MessageRecord) {
        guard canEdit(message), case let .text(text, _) = message.content else { return }
        let chat = message.chat
        if editing[chat] == nil {
            textBeforeEdit[chat] = composerText[chat] ?? ""
            mentionsBeforeEdit[chat] = composerMentions.removeValue(forKey: chat)
        }
        replyingTo[chat] = nil
        editing[chat] = message
        composerText[chat] = text
        composerFocusRequests += 1
    }

    /// Up Arrow in an empty composer edits the newest message that still
    /// can be, as upstream does. Returns whether there was one.
    @discardableResult
    public func editLastMessage(in chat: String) -> Bool {
        guard editing[chat] == nil,
              let message = conversations.conversation(chat).messages.last(where: { canEdit($0) })
        else { return false }
        startEditing(message)
        return true
    }

    public func cancelEditing(in chat: String) {
        guard editing.removeValue(forKey: chat) != nil else { return }
        composerText[chat] = textBeforeEdit.removeValue(forKey: chat) ?? ""
        composerMentions[chat] = mentionsBeforeEdit.removeValue(forKey: chat) ?? nil
    }

    /// Sends the changed text; the worker files it and sends the message
    /// back updated. Mentions still named in the text are kept, and new
    /// ones picked while editing are added.
    private func finishEditing(_ message: MessageRecord, with text: String) {
        let chat = message.chat
        let (text, picked) = encodeMentions(text, in: chat)
        cancelEditing(in: chat)
        stopComposing(in: chat)
        guard case let .text(original, _) = message.content, text != original else { return }
        let kept = message.mentions
            .filter { MentionEncoding.containsToken(text, user: $0.user) && !picked.contains($0.id) }
            .map(\.id)
        backend.send(.editText(chat: chat, id: message.id, text: text, mentions: picked + kept))
    }

    public func cancelReply(in chat: String) {
        replyingTo[chat] = nil
    }
}
