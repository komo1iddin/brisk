import Foundation
import Observation
import OSLog
import ZapFastBridge

/// The app's root state: owns the backend connection and the stores, turns
/// backend events into state, and turns user intents into commands.
///
/// This plays the part of upstream's `App` (src/app.rs) minus everything
/// egui: views read the stores and call the intent methods here.
@Observable
public final class AppModel {
    public let session: SessionStore
    public let chats: ChatStore
    public let conversations: ConversationStore
    public let avatars: AvatarStore

    /// The chat open in the conversation pane.
    public var selectedChatID: String? {
        didSet {
            guard selectedChatID != oldValue else { return }
            if let oldValue { flushDraft(for: oldValue) }
            if let selectedChatID { opened(selectedChatID) }
        }
    }

    /// Transient messages for the notice banner, oldest first.
    public private(set) var notices: [Notice] = []

    /// Composer text per chat, including unsaved edits.
    public var composerText: [String: String] = [:]

    /// The message the composer replies to, per chat.
    public var replyingTo: [String: MessageRecord] = [:]

    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private var started = false
    @ObservationIgnored private let log = Logger(subsystem: "ZapFast", category: "AppModel")
    /// Chats we told the backend we are typing in, and the task that will
    /// say we stopped.
    @ObservationIgnored private var composingIn: [String: Task<Void, Never>] = [:]

    public init(backend: Backend = LiveBackend(), paths: AppPaths = .standard()) {
        let session = SessionStore()
        self.session = session
        self.chats = ChatStore(session: session)
        self.conversations = ConversationStore()
        self.backend = backend
        self.paths = paths
        self.avatars = AvatarStore(send: backend.send)
    }

    // MARK: Lifecycle

    public func start(verbose: Bool = false) {
        guard !started else { return }
        started = true
        do {
            try backend.start(paths: paths, verbose: verbose) { [weak self] events in
                self?.apply(events)
            }
        } catch BridgeError.AnotherInstance {
            session.link = .failed(message: String(localized: "ZapFast is already running."))
        } catch BridgeError.Storage(let message) {
            session.link = .failed(message: String(localized: "Could not prepare ZapFast's folders: \(message)"))
        } catch {
            session.link = .failed(message: String(describing: error))
        }
    }

    public func shutdown() {
        guard started else { return }
        if let selectedChatID { flushDraft(for: selectedChatID) }
        backend.shutdown()
        started = false
    }

    /// Linked data exists, even while offline; upstream's `App::is_linked`.
    public var isLinked: Bool {
        session.linkSaysLinked || (!chats.chats.isEmpty && !session.isLoggedOut)
    }

    public var logFile: URL { paths.logFile }

    // MARK: Intents: link

    public func pair(phone: String) {
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty else { return }
        backend.send(.pairWithPhone(phone: digits))
    }

    public func reconnect() { backend.send(.reconnect) }
    public func unlink() { backend.send(.unlink) }
    public func startOverArchive() { backend.send(.startOverArchive) }

    /// Whether the person is looking at the app; the phone keeps its push
    /// notifications while they are not.
    public func setActive(_ active: Bool) {
        guard started else { return }
        backend.send(.setOnline(online: active))
    }

    // MARK: Intents: conversation

    public func loadOlder(in chat: String) {
        let conversation = conversations.conversation(chat)
        guard !conversation.loadingOlder else { return }
        if !conversation.complete, let key = conversation.oldestKey {
            conversations.markLoadingOlder(chat)
            backend.send(.loadChat(chat: chat, before: key))
        } else if conversation.complete, !conversation.fetchingPhone, !conversation.phoneExhausted,
                  session.isConnected {
            conversations.markFetchingPhone(chat)
            backend.send(.fetchOlder(chat: chat))
        }
    }

    public func sendText(in chat: String) {
        let text = (composerText[chat] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let quoting = replyingTo.removeValue(forKey: chat)?.id
        composerText[chat] = ""
        chats.setDraft("", for: chat)
        backend.send(.saveDraft(chat: chat, text: ""))
        stopComposing(in: chat)
        backend.send(.sendText(chat: chat, text: text, quoting: quoting, mentions: []))
    }

    public func reply(to message: MessageRecord) {
        replyingTo[message.chat] = message
    }

    public func cancelReply(in chat: String) {
        replyingTo[chat] = nil
    }

    public func sendFiles(_ urls: [URL], in chat: String, caption: String? = nil) {
        guard !urls.isEmpty else { return }
        backend.send(.sendFiles(
            chat: chat,
            paths: urls.map { $0.path(percentEncoded: false) },
            caption: caption,
            mentions: [],
            quoting: nil
        ))
    }

    /// The composer changed: tell the chat we are typing, and that we
    /// stopped once the keys have been quiet for a few seconds.
    public func composerEdited(in chat: String) {
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

    private func stopComposing(in chat: String) {
        guard let task = composingIn.removeValue(forKey: chat) else { return }
        task.cancel()
        backend.send(.composing(chat: chat, composing: false))
    }

    public func download(_ message: MessageRecord) {
        let key = MessageKey(chat: message.chat, message: message.id)
        guard conversations.downloads[key] != .downloading else { return }
        conversations.startDownload(key)
        backend.send(.download(chat: message.chat, message: message.id, card: nil))
    }

    public func react(_ emoji: String, to message: MessageRecord) {
        backend.send(.react(chat: message.chat, message: message.id, emoji: emoji))
    }

    public func deleteForEveryone(_ message: MessageRecord) {
        backend.send(.revoke(chat: message.chat, id: message.id))
    }

    public func deleteForMe(_ message: MessageRecord) {
        backend.send(.deleteLocal(chat: message.chat, id: message.id))
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
        backend.send(.markRead(chat: chat, receipts: true))
    }

    public func markUnread(_ chat: String) {
        backend.send(.markUnread(chat: chat))
    }

    public func dismissNotice(_ notice: Notice) {
        notices.removeAll { $0.id == notice.id }
    }

    // MARK: Opening a chat

    private func opened(_ chat: String) {
        if composerText[chat] == nil, let draft = chats.drafts[chat] {
            composerText[chat] = draft
        }
        ensureLoaded(chat)
        if chats.chat(chat)?.looksUnread == true {
            markRead(chat)
        }
    }

    private func ensureLoaded(_ chat: String) {
        guard !conversations.conversation(chat).requested else { return }
        conversations.markRequested(chat)
        backend.send(.loadChat(chat: chat, before: nil))
    }

    private func flushDraft(for chat: String) {
        let text = composerText[chat] ?? ""
        guard text != (chats.drafts[chat] ?? "") else { return }
        chats.setDraft(text, for: chat)
        backend.send(.saveDraft(chat: chat, text: text))
        stopComposing(in: chat)
    }

    // MARK: Events

    func apply(_ events: [BridgeEvent]) {
        for event in events {
            apply(event)
        }
    }

    private func apply(_ event: BridgeEvent) {
        switch event {
        case .link(let state):
            applyLink(state)
        case let .me(id, lid, name, about):
            session.account = .init(id: id, lid: lid, name: name, about: about)
        case .chats(let list):
            chats.replaceAll(list)
        case .chatUpdated(let chat):
            chats.upsert(chat)
            // An open chat that turns unread was read by the person looking at it.
            if chat.id == selectedChatID, chat.looksUnread, !chat.markedUnread {
                markRead(chat.id)
            }
        case .chatRemoved(let chat):
            chats.remove(chat)
            conversations.forget(chat)
            if selectedChatID == chat { selectedChatID = nil }
        case let .chatCleared(chat, through):
            conversations.applyCleared(chat: chat, through: through)
        case .drafts(let drafts):
            chats.replaceDrafts(drafts)
        case let .messages(chat, messages, older, complete):
            let bare = conversations.applyMessages(
                chat: chat, messages: messages, older: older, complete: complete
            )
            if bare, chat == selectedChatID { loadOlder(in: chat) }
        case .messageUpdated(let message):
            conversations.applyUpdated(message)
        case let .messageDeleted(chat, id):
            conversations.applyDeleted(chat: chat, id: id)
        case .incoming:
            // Desktop notifications arrive with the notifications feature.
            break
        case .contacts(let contacts):
            chats.replaceContacts(contacts)
        case .searchHits, .chatHits:
            // Message search arrives with the search feature.
            break
        case let .typing(chat, sender, composing):
            conversations.applyTyping(chat: chat, sender: sender, composing: composing)
        case let .presence(id, online, lastSeen):
            conversations.applyPresence(id: id, online: online, lastSeen: lastSeen)
        case let .avatar(id, full, path):
            avatars.apply(id: id, full: full, path: path)
        case let .media(chat, message, _, path, error):
            conversations.applyMedia(chat: chat, message: message, path: path, error: error)
        case .syncing(let active):
            session.isSyncing = active
            if !active { session.syncProgress = nil }
        case .syncProgress(let percent):
            session.syncProgress = percent
        case let .olderFetched(chat, more):
            conversations.applyOlderFetched(chat: chat, more: more)
        case .receiptsPrivacy(let disabled):
            session.receiptsDisabled = disabled
        case .pinLimit(let limit):
            session.pinLimit = limit
        case let .sendRefused(chat, _, reason, text):
            if let text, (composerText[chat] ?? "").isEmpty {
                composerText[chat] = text
            }
            post(.error, reason == .offline
                ? String(localized: "Not sent: you are offline.")
                : String(localized: "Not sent: the quoted message is unavailable."))
        case .info(let message):
            post(.info, message)
        case .error(let message):
            post(.error, message)
        case .notBridged(let name):
            log.debug("event not bridged yet: \(name, privacy: .public)")
        }
    }

    private func applyLink(_ state: LinkState) {
        let wasDisconnected = if case .disconnected = session.link { true } else { false }
        switch state {
        case .connected:
            if wasDisconnected { post(.info, String(localized: "Back online")) }
            avatars.forgetMisses()
            if let selectedChatID { ensureLoaded(selectedChatID) }
        case .loggedOut:
            chats.clear()
            conversations.clear()
            avatars.clear()
            composerText = [:]
            replyingTo = [:]
            selectedChatID = nil
            post(.error, String(localized: "This device was unlinked from your phone"))
        case .failed(let message):
            post(.error, message)
        case .starting, .unlinked, .connecting, .disconnected:
            break
        }
        session.link = state
    }

    private func post(_ kind: Notice.Kind, _ text: String) {
        notices.append(Notice(kind: kind, text: text))
        if notices.count > 3 { notices.removeFirst(notices.count - 3) }
    }
}

public struct Notice: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case info, error }
    public let id = UUID()
    public let kind: Kind
    public let text: String
}
