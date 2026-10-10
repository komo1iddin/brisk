/// Polls, and the buttons and lists a business message offers.
///
/// Part of `AppModel`, in a file of its own so that one file is one
/// subject; the state these read and write lives on the class.

import Foundation
import ZapFastBridge

extension AppModel {
    // MARK: Intents: polls

    /// Sends a new poll once upstream's rules accept it, one at a time.
    public func createPoll(_ draft: PollDraftInfo, in chat: String) {
        guard pollDraftProblem(draft: draft) == nil, session.isConnected, !pollCreating else { return }
        pollCreating = true
        backend.send(.createPoll(chat: chat, draft: draft))
        followSentChat()
    }

    /// Votes by clicking an option, while connected and with no vote of
    /// ours already on its way.
    public func vote(_ message: MessageRecord, option: Int) {
        guard case let .poll(_, _, state) = message.content, state.canVote, session.isConnected else { return }
        let key = MessageKey(chat: message.chat, message: message.id)
        guard !pollVoting.contains(key),
              let choices = PollBallot.choices(afterClicking: UInt32(option), in: state) else { return }
        pollVoting.insert(key)
        backend.send(.votePoll(chat: message.chat, message: message.id, choices: choices))
    }

    /// A poll came into view: ask the phone for its earlier votes when
    /// upstream says they are missing, once.
    public func pollAppeared(_ message: MessageRecord) {
        guard case let .poll(_, _, state) = message.content, state.refreshNeeded, !state.refreshing,
              session.isConnected else { return }
        let key = MessageKey(chat: message.chat, message: message.id)
        guard pollRefreshAsked.insert(key).inserted else { return }
        backend.send(.refreshPoll(chat: message.chat, message: message.id))
    }

    public func showPollResults(_ message: MessageRecord) {
        pollResults = MessageKey(chat: message.chat, message: message.id)
    }

    // MARK: Intents: business messages

    /// Upstream's rule for a button that sends: connected, a chat we can
    /// write in, someone else's unedited message, no reply already going.
    public func canAnswer(_ message: MessageRecord) -> Bool {
        guard session.isConnected, !message.fromMe, !message.edited,
              let chat = chats.chat(message.chat), chat.canSend else { return false }
        return !interactiveSending.contains(MessageKey(chat: message.chat, message: message.id))
    }

    /// Why a sending button is off, in upstream's words, or nil when it works.
    public func answerProblem(_ message: MessageRecord) -> String? {
        if interactiveSending.contains(MessageKey(chat: message.chat, message: message.id)) {
            return String(localized: "Sending reply…")
        }
        if !session.isConnected { return String(localized: "Connect to WhatsApp to reply") }
        if chats.chat(message.chat)?.canSend != true { return String(localized: "This conversation is read-only") }
        if message.fromMe { return String(localized: "Reply options are for the recipient") }
        if message.edited { return String(localized: "Open this option in WhatsApp Web or on your phone") }
        return nil
    }

    /// Presses a quick-reply button, or picks `choice` from a list button.
    /// Only indices go out; the worker re-reads the ids from the archive.
    public func answer(_ message: MessageRecord, button: Int, choice: Int? = nil) {
        guard canAnswer(message) else { return }
        interactiveList = nil
        backend.send(.replyInteractive(
            chat: message.chat, message: message.id, button: UInt32(button), choice: choice.map(UInt32.init)
        ))
        followSentChat()
    }

    public func showChoices(_ message: MessageRecord, button: Int) {
        guard canAnswer(message) else { return }
        interactiveList = InteractiveListRequest(key: MessageKey(chat: message.chat, message: message.id), button: button)
    }

    /// Downloads a carousel card's image.
    public func downloadCard(_ message: MessageRecord, card: Int) {
        let key = CardKey(message: MessageKey(chat: message.chat, message: message.id), card: card)
        guard conversations.cardDownloads[key] != .downloading,
              let media = message.content.media(card: card), media.path == nil else { return }
        conversations.startDownload(key)
        backend.send(.download(chat: message.chat, message: message.id, card: UInt32(card)))
    }
}
