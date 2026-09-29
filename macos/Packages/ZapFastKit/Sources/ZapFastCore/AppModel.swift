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
    public let preferences: Preferences
    public let search = SearchStore()
    public let stickers = StickerStore()
    public let voice = VoicePlayer()
    public let recorder = VoiceRecorder()

    /// The chat open in the conversation pane.
    public var selectedChatID: String? {
        didSet {
            guard selectedChatID != oldValue else { return }
            // No player outlives its chat until there is a mini player,
            // and a recording belongs to the chat it started in.
            if voice.current?.chat != selectedChatID { voice.stop() }
            if recorder.isRecording { recorder.cancel() }
            if search.chat?.chat != selectedChatID { search.chat = nil }
            infoShown = false
            if pendingJump?.chat != selectedChatID { pendingJump = nil }
            if let oldValue {
                // An unfinished edit is dropped, not kept as a draft.
                cancelEditing(in: oldValue)
                flushDraft(for: oldValue)
            }
            if let selectedChatID { opened(selectedChatID) }
        }
    }

    /// Brings the app's window forward; the shell provides it.
    @ObservationIgnored public var bringToFront: () -> Void = {}

    /// Transient messages for the notice banner, oldest first.
    public private(set) var notices: [Notice] = []

    /// Composer text per chat, including unsaved edits.
    public var composerText: [String: String] = [:]

    /// The message the composer replies to, per chat.
    public var replyingTo: [String: MessageRecord] = [:]

    /// The open chat's info panel is showing.
    public private(set) var infoShown = false

    /// The New Chat sheet is open.
    public var newChatShown = false
    /// A number is being checked with WhatsApp.
    public private(set) var newContactPending = false

    /// Groups whose name or photo change is on its way to WhatsApp.
    public private(set) var groupSaving: Set<String> = []

    /// Polls whose vote is on its way.
    public private(set) var pollVoting: Set<MessageKey> = []
    /// The poll whose results sheet is open.
    public var pollResults: MessageKey?

    /// Messages waiting for the person to pick where to forward them.
    public private(set) var forwarding: ForwardRequest?

    /// The message the composer is editing, per chat.
    public private(set) var editing: [String: MessageRecord] = [:]
    /// Bumped to put the cursor back in the composer.
    public private(set) var composerFocusRequests = 0

    /// A message the timeline should scroll to; the token tells a second
    /// jump to the same message apart from the first.
    public private(set) var jump: JumpRequest?
    /// The message just jumped to, marked for a moment so the eye finds it.
    public private(set) var highlighted: MessageKey?
    /// Bumped to put the cursor in the sidebar's search field.
    public private(set) var sidebarSearchRequests = 0
    /// Bumped to put the cursor in the open chat's search field.
    public private(set) var chatSearchFocusRequests = 0

    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private var started = false
    @ObservationIgnored private var verbose = false
    @ObservationIgnored private let log = Logger(subsystem: "ZapFast", category: "AppModel")
    /// Chats we told the backend we are typing in, and the task that will
    /// say we stopped.
    @ObservationIgnored private var composingIn: [String: Task<Void, Never>] = [:]
    /// Voice messages we already sent a played receipt for.
    @ObservationIgnored private var playedTold: Set<String> = []
    /// Created on start: Notification Center needs a real app bundle.
    @ObservationIgnored private var notifier: Notifier?
    /// The person is looking at the app.
    @ObservationIgnored private var isActive = true
    /// A jump waiting for its message to load, and whether the archive was
    /// already asked for the pages up to it.
    @ObservationIgnored private var pendingJump: MessageKey?
    @ObservationIgnored private var jumpAskedArchive = false
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    @ObservationIgnored private var messageSearchTask: Task<Void, Never>?
    /// Polls whose earlier votes were already asked of the phone; the
    /// backend keeps retrying on its own after that.
    @ObservationIgnored private var pollRefreshAsked: Set<MessageKey> = []
    /// What the composer held before an edit took it over, per chat.
    @ObservationIgnored private var textBeforeEdit: [String: String] = [:]
    @ObservationIgnored private var gifSearchTask: Task<Void, Never>?
    @ObservationIgnored private var wantedGifQuery: String?
    /// The query the sidebar's message hits should answer.
    @ObservationIgnored private var wantedMessageQuery = ""
    @ObservationIgnored private var chatSearchTask: Task<Void, Never>?

    public init(
        backend: Backend = LiveBackend(),
        paths: AppPaths = .standard(),
        preferences: Preferences = Preferences()
    ) {
        self.preferences = preferences
        let session = SessionStore()
        self.session = session
        self.chats = ChatStore(session: session)
        self.conversations = ConversationStore()
        self.backend = backend
        self.paths = paths
        self.avatars = AvatarStore(send: backend.send)
        voice.onFinished = { [weak self] key in self?.continueVoice(after: key) }
    }

    // MARK: Lifecycle

    public func start(verbose: Bool = false) {
        guard !started else { return }
        started = true
        // Notification Center needs a real app bundle, which only the live
        // backend runs in.
        if notifier == nil, backend is LiveBackend {
            let notifier = Notifier()
            notifier.onResponse = { [weak self] response in self?.handle(response) }
            notifier.requestAuthorization()
            self.notifier = notifier
        }
        self.verbose = verbose
        do {
            try backend.start(paths: paths, verbose: verbose) { [weak self] events in
                self?.apply(events)
            }
            session.link = .starting
        } catch BridgeError.AnotherInstance {
            session.link = .failed(message: String(localized: "ZapFast is already running."))
        } catch BridgeError.Storage(let message) {
            session.link = .failed(message: String(localized: "Could not prepare ZapFast's folders: \(message)"))
        } catch {
            session.link = .failed(message: String(describing: error))
        }
        // A backend that never started can be started again (Try Again).
        if case .failed = session.link { started = false }
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

    /// Reconnects, or retries starting when the backend never came up.
    public func reconnect() {
        guard started else {
            start(verbose: verbose)
            return
        }
        backend.send(.reconnect)
    }
    public func unlink() { backend.send(.unlink) }
    public func startOverArchive() { backend.send(.startOverArchive) }

    /// Whether the person is looking at the app; the phone keeps its push
    /// notifications while they are not.
    public func setActive(_ active: Bool) {
        isActive = active
        guard started else { return }
        backend.send(.setOnline(online: active))
        if active, let selectedChatID { notifier?.clear(chat: selectedChatID) }
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
        if let message = editing[chat] {
            finishEditing(message, with: text)
            return
        }
        let quoting = replyingTo.removeValue(forKey: chat)?.id
        composerText[chat] = ""
        chats.setDraft("", for: chat)
        backend.send(.saveDraft(chat: chat, text: ""))
        stopComposing(in: chat)
        backend.send(.sendText(chat: chat, text: text, quoting: quoting, mentions: []))
    }

    public func reply(to message: MessageRecord) {
        // Replying while editing starts a new message: the edited text
        // must not go out as the reply.
        cancelEditing(in: message.chat)
        replyingTo[message.chat] = message
        composerFocusRequests += 1
    }

    // MARK: Intents: chat info

    /// Shows the open chat's info in place of its search, which shares the
    /// same side of the window.
    public func showInfo() {
        guard selectedChatID != nil else { return }
        closeChatSearch()
        infoShown = true
    }

    public func closeInfo() {
        infoShown = false
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
            toPhone: preferences.saveContactsToPhone
        ))
    }

    /// Opens the chat with a person, creating it in the archive first when
    /// there is none yet (upstream's `StartChat`).
    public func startChat(with id: String, name: String? = nil) {
        newChatShown = false
        if chats.chat(id) == nil {
            backend.send(.ensureChat(chat: id, name: name ?? chats.personName(id, hint: nil)))
        }
        selectedChatID = id
    }

    // MARK: Intents: stickers and GIFs

    /// The picker opened: load its stickers, as upstream does each time.
    public func loadStickers() {
        backend.send(.recentStickers)
    }

    /// Sends a sticker, replying if a reply is set.
    public func sendSticker(_ path: String, in chat: String) {
        let quoting = replyingTo.removeValue(forKey: chat)?.id
        backend.send(.sendSticker(chat: chat, path: path, quoting: quoting))
    }

    public func toggleFavoriteSticker(_ path: String) {
        backend.send(stickers.isFavorite(path) ? .forgetSticker(path: path) : .saveSticker(path: path))
    }

    public func removeRecentSticker(_ path: String) {
        backend.send(.removeRecentSticker(path: path))
    }

    /// Whether GIF search has a key: ours, or one built into upstream.
    public var canSearchGifs: Bool {
        giphyKey(own: preferences.giphyKey) != nil
    }

    /// Searches GIPHY once typing pauses; an empty query lists trending.
    public func searchGifs(_ text: String) {
        gifSearchTask?.cancel()
        guard let key = giphyKey(own: preferences.giphyKey) else { return }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        wantedGifQuery = query
        stickers.gifPending = true
        gifSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.backend.send(.searchGifs(query: query, key: key))
        }
    }

    public func sendGif(_ gif: GifInfo, in chat: String) {
        let quoting = replyingTo.removeValue(forKey: chat)?.id
        backend.send(.sendGif(chat: chat, gif: gif, quoting: quoting))
    }

    // MARK: Intents: groups and contacts

    /// Every id we may be listed under, for `canLeave(ours:)`.
    public var ourIDs: [String] {
        guard let account = session.account else { return [] }
        return [account.id] + (account.lid.map { [$0] } ?? [])
    }

    public func renameGroup(_ chat: ChatSummary, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard chat.canEditInfo, !groupSaving.contains(chat.id), !name.isEmpty,
              name != chat.name else { return }
        backend.send(.setGroupName(chat: chat.id, name: name))
    }

    /// Makes a picture file the group's photo, squared and scaled as
    /// upstream does first.
    public func setGroupPicture(_ chat: ChatSummary, from url: URL) {
        guard chat.canEditInfo, !groupSaving.contains(chat.id) else { return }
        Task {
            do {
                let jpeg = try await PictureEncoding.squareJPEG(from: url)
                backend.send(.setGroupPicture(chat: chat.id, jpeg: jpeg))
            } catch {
                post(.error, String(localized: "Could not use this picture: \(error.localizedDescription)"))
            }
        }
    }

    public func removeGroupPicture(_ chat: ChatSummary) {
        guard chat.canEditInfo, !groupSaving.contains(chat.id) else { return }
        backend.send(.setGroupPicture(chat: chat.id, jpeg: nil))
    }

    public func leaveGroup(_ chat: ChatSummary, archive: Bool) {
        guard chat.canLeave(ours: ourIDs) else { return }
        backend.send(.leaveGroup(chat: chat.id, archive: archive))
    }

    /// Saves a person's name through contact sync (upstream's SaveContact).
    public func saveContact(_ id: String, first: String, last: String) {
        guard let name = ContactName.compose(first: first, last: last) else { return }
        backend.send(.saveContact(
            id: id, fullName: name.full, firstName: name.short, toPhone: preferences.saveContactsToPhone
        ))
    }

    // MARK: Intents: polls

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

    /// Sends the waiting messages to `chat`, oldest first as upstream does.
    public func forward(to chat: String) {
        guard let request = forwarding else { return }
        forwarding = nil
        backend.send(.forward(fromChat: request.chat, messages: request.messages, toChat: chat))
        let name = chats.chat(chat).map(chats.title(for:)) ?? chats.displayName(chat)
        post(.info, String(localized: "Forwarded to \(name)"))
    }

    public func cancelForward() {
        forwarding = nil
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
        if editing[chat] == nil { textBeforeEdit[chat] = composerText[chat] ?? "" }
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
    }

    /// Sends the changed text; the worker files it and sends the message
    /// back updated. Mentions still named in the text are kept.
    private func finishEditing(_ message: MessageRecord, with text: String) {
        let chat = message.chat
        cancelEditing(in: chat)
        stopComposing(in: chat)
        guard case let .text(original, _) = message.content, text != original else { return }
        let mentions = message.mentions.filter { text.contains("@\($0.user)") }.map(\.id)
        backend.send(.editText(chat: chat, id: message.id, text: text, mentions: mentions))
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

    // MARK: Intents: voice messages

    /// Plays or pauses a voice message or audio attachment, downloading it
    /// first if needed.
    public func playAudio(_ message: MessageRecord) {
        guard case let .audio(media, _, voiceNote, _) = message.content else { return }
        guard let url = message.mediaURL else {
            download(message)
            return
        }
        let key = MessageKey(chat: message.chat, message: message.id)
        let opus = media.mime.contains("ogg") || media.mime.contains("opus")
        let speed = voiceNote ? preferences.voiceSpeed : 1
        Task { await voice.toggle(key, url: url, opus: opus, speed: speed) }
        if voiceNote, !message.fromMe, playedTold.insert(message.id).inserted {
            backend.send(.markPlayed(
                chat: message.chat,
                message: message.id,
                sender: message.sender,
                receipts: preferences.sendReadReceipts
            ))
        }
    }

    public func seekAudio(_ message: MessageRecord, to fraction: Double) {
        guard voice.isCurrent(MessageKey(chat: message.chat, message: message.id)) else {
            playAudio(message)
            return
        }
        voice.seek(to: fraction)
    }

    /// Starts recording a voice message; playback stops first.
    public func startRecording() {
        voice.stop()
        Task {
            if await !recorder.start(), recorder.state == .denied {
                post(.error, String(localized: "ZapFast can't use the microphone. Allow it in System Settings › Privacy & Security › Microphone."))
            }
        }
    }

    /// Sends the recording to `chat`, replying if a reply is set. Upstream
    /// drops recordings shorter than half a second.
    public func sendRecording(in chat: String) {
        let samples = recorder.finish()
        guard samples.count >= Int(voiceSampleRate()) / 2 else { return }
        let quoting = replyingTo.removeValue(forKey: chat)?.id
        backend.send(.sendVoice(chat: chat, samples: samples, quoting: quoting))
    }

    public func cancelRecording() {
        recorder.cancel()
    }

    /// 1× → 1.5× → 2× → 1×, as on the phone.
    public func cycleVoiceSpeed() {
        let next: Float = switch preferences.voiceSpeed {
        case ..<1.25: 1.5
        case ..<1.75: 2
        default: 1
        }
        preferences.voiceSpeed = next
        voice.setSpeed(next)
    }

    /// Upstream plays the next voice message of a run by itself.
    private func continueVoice(after key: MessageKey) {
        let messages = conversations.conversation(key.chat).messages
        guard let index = messages.firstIndex(where: { $0.id == key.message }),
              messages.indices.contains(index + 1) else { return }
        let next = messages[index + 1]
        guard case .audio(_, _, true, _) = next.content, !next.fromMe, next.mediaURL != nil else { return }
        playAudio(next)
    }

    /// Upstream's largest automatic or manual download (`ATTACHMENT_DOWNLOAD_LIMIT`).
    public static let downloadLimit: UInt64 = 64 * 1024 * 1024

    /// Upstream's rule for media scrolled into view: stickers always, other
    /// media when automatic downloads are on, never past the size limit,
    /// and never again after a failure until asked.
    public func autoDownload(_ message: MessageRecord) {
        guard let media = message.content.media, media.path == nil, media.size <= Self.downloadLimit else { return }
        let isSticker = if case .sticker = message.content { true } else { false }
        guard isSticker || preferences.autoDownload else { return }
        guard conversations.downloads[MessageKey(chat: message.chat, message: message.id)] == nil else { return }
        download(message)
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
        backend.send(.markRead(chat: chat, receipts: preferences.sendReadReceipts))
    }

    public func markUnread(_ chat: String) {
        backend.send(.markUnread(chat: chat))
    }

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
    /// and puts the cursor in its field.
    public func openChatSearch() {
        guard let chat = selectedChatID else { return }
        infoShown = false
        if search.chat?.chat != chat { search.chat = ChatSearch(chat: chat) }
        chatSearchFocusRequests += 1
    }

    public func closeChatSearch() {
        chatSearchTask?.cancel()
        search.chat = nil
    }

    /// The in-chat search text changed. The earlier matches stay listed
    /// until the answer replaces them, so the list does not blink empty on
    /// every keystroke.
    public func setChatSearchQuery(_ text: String) {
        guard var current = search.chat, current.query != text else { return }
        current.query = text
        chatSearchTask?.cancel()
        let query = current.trimmedQuery
        if query.isEmpty {
            current.hits = []
            current.truncated = false
            current.pending = false
            current.selected = nil
            search.chat = current
            return
        }
        current.pending = true
        search.chat = current
        let chat = current.chat
        chatSearchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDelay)
            guard !Task.isCancelled else { return }
            self?.backend.send(.searchChatMessages(chat: chat, query: query, from: nil, until: nil))
        }
    }

    /// Reveals the match at `index` of the in-chat results.
    public func revealChatSearchHit(_ index: Int) {
        guard var current = search.chat, current.hits.indices.contains(index) else { return }
        current.selected = index
        search.chat = current
        open(current.hits[index])
    }

    /// Moves through the in-chat results: `older` goes down the list, which
    /// is newest first, as Find Next goes down a page.
    public func stepChatSearch(older: Bool) {
        guard let current = search.chat, !current.hits.isEmpty else { return }
        let next: Int = switch current.selected {
        case nil: 0
        case let index?: older ? min(index + 1, current.hits.count - 1) : max(index - 1, 0)
        }
        revealChatSearchHit(next)
    }

    /// Opens a message's chat and scrolls to it, loading the archive up to
    /// it first when it is older than what is loaded.
    public func open(_ message: MessageRecord) {
        reveal(MessageKey(chat: message.chat, message: message.id))
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
    private func continueJump() {
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
            if !chat.looksUnread { notifier?.clear(chat: chat.id) }
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
            if pendingJump?.chat == chat { continueJump() }
        case .messageUpdated(let message):
            conversations.applyUpdated(message)
        case let .messageDeleted(chat, id):
            conversations.applyDeleted(chat: chat, id: id)
        case let .incoming(chat, message):
            maybeNotify(chat: chat, message: message)
        case .contacts(let contacts):
            chats.replaceContacts(contacts)
        case let .searchHits(query, messages):
            let visible = messages.filter { chats.chat($0.chat)?.locked != true }
            search.applyMessageHits(query: query, messages: visible, wanted: wantedMessageQuery)
        case let .chatHits(chat, query, from, until, messages, truncated):
            // The panel never asks for a day range yet, so an answer with
            // one was asked for by something else.
            guard from == nil, until == nil else { break }
            search.applyChatHits(chat: chat, query: query, messages: messages, truncated: truncated)
        case .stickers(let library):
            stickers.apply(library)
        case let .gifs(query, gifs, error):
            stickers.applyGifs(query: query, gifs: gifs, error: error, wanted: wantedGifQuery ?? "")
        case let .contactReady(id, name):
            newContactPending = false
            startChat(with: id, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? phoneOf(id: id))
        case let .groupSaving(chat, saving):
            if saving { groupSaving.insert(chat) } else { groupSaving.remove(chat) }
        case let .pollVoted(chat, message, error):
            pollVoting.remove(MessageKey(chat: chat, message: message))
            if let error { post(.error, error) }
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
            // A number WhatsApp does not know ends its check with an error.
            newContactPending = false
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
            search.clear()
            stickers.clear()
            avatars.clear()
            composerText = [:]
            replyingTo = [:]
            editing = [:]
            textBeforeEdit = [:]
            forwarding = nil
            pollVoting = []
            groupSaving = []
            pollResults = nil
            pollRefreshAsked = []
            notifier?.clearAll()
            selectedChatID = nil
            post(.error, String(localized: "This device was unlinked from your phone"))
        case .failed(let message):
            post(.error, message)
        case .starting, .unlinked, .connecting, .disconnected:
            break
        }
        session.link = state
    }

    // MARK: Notifications (upstream's `maybe_notify`)

    private func maybeNotify(chat id: String, message: MessageRecord) {
        guard preferences.notifications, !message.fromMe, let chat = chats.chat(id) else { return }
        let now = Int64(Date.now.timeIntervalSince1970)
        guard !chat.archived, chat.unread > 0, !chats.isMuted(chat), !chat.locked,
              now - message.timestamp <= 60 else { return }
        let reading = isActive && selectedChatID == id
        guard !reading else { return }

        guard preferences.notificationPreviews else {
            notifier?.post(chat: id, message: message.id, title: "ZapFast",
                           body: String(localized: "New message"), picture: nil)
            return
        }
        let title = chats.title(for: chat)
        let text = messageText(message)
        let body = chat.kind == .group
            ? "\(chats.displayName(message.sender, hint: message.senderName)): \(text)"
            : text
        let picture = avatars.url(for: id) ?? avatars.url(for: message.sender)
        notifier?.post(chat: id, message: message.id, title: title, body: body, picture: picture)
    }

    /// A message's summary with `@number` mention tokens shown as names.
    public func messageText(_ message: MessageRecord) -> String {
        message.mentions.reduce(message.summary) { text, mention in
            text.replacingOccurrences(of: "@\(mention.user)", with: "@\(chats.displayName(mention.id))")
        }
    }

    private func handle(_ response: Notifier.Response) {
        switch response {
        case let .open(chat, _):
            selectedChatID = chat
            bringToFront()
        case let .reply(chat, message, text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            backend.send(.sendText(chat: chat, text: trimmed, quoting: message, mentions: []))
            markRead(chat)
        case .markRead(let chat):
            markRead(chat)
        }
    }

    private func post(_ kind: Notice.Kind, _ text: String) {
        notices.append(Notice(kind: kind, text: text))
        if notices.count > 3 { notices.removeFirst(notices.count - 3) }
    }
}

public struct ForwardRequest: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let chat: String
    /// Message ids in the source chat.
    public let messages: [String]
}

public struct JumpRequest: Equatable, Sendable {
    public let key: MessageKey
    public let token = UUID()
}

public struct Notice: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case info, error }
    public let id = UUID()
    public let kind: Kind
    public let text: String
}
