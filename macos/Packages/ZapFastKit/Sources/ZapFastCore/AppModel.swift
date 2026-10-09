import Foundation
import ImageIO
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
    /// This account's own preferences (upstream's `AccountSettings`).
    public let accountPreferences: AccountPreferences
    public let search = SearchStore()
    public let stickers = StickerStore()
    public let privacy = PrivacyStore()
    public let themes: ThemeStore
    public let voice = VoicePlayer()
    public let video = VideoPlayback()
    public let recorder = VoiceRecorder()
    public let calls: CallStore
    public let appLock: AppLock
    public let lockedChats: LockedChats

    /// The chat open in the conversation pane.
    public var selectedChatID: String? {
        didSet {
            guard selectedChatID != oldValue else { return }
            // No player outlives its chat until there is a mini player,
            // and a recording belongs to the chat it started in.
            if let playing = voice.current?.chat, !isOpen(playing) { voice.stop() }
            if let playing = video.current?.chat, !isOpen(playing) { video.stop() }
            if recorder.isRecording { recorder.cancel() }
            if let searched = search.chat?.chat, !isOpen(searched) { search.chat = nil }
            if infoChat == oldValue { closeInfo() }
            if messageInfo?.chat != selectedChatID { messageInfo = nil }
            if pendingJump?.chat != selectedChatID { pendingJump = nil }
            if videoWanted?.chat != selectedChatID { videoWanted = nil }
            if unreadDivider?.chat != selectedChatID { unreadDivider = nil }
            if selection?.chat != selectedChatID { selection = nil }
            if mediaViewer?.chat != selectedChatID { mediaViewer = nil }
            reactionTarget = nil
            if let oldValue {
                // Staged attachments belong to the chat left, as upstream's
                // do; a caption written for them stays as the draft.
                discardAttachments(in: oldValue)
                // An unfinished edit is dropped, not kept as a draft.
                cancelEditing(in: oldValue)
                flushDraft(for: oldValue)
            }
            if let selectedChatID { opened(selectedChatID) }
            // What is open now opens at the next start; a locked chat never does.
            accountPreferences.lastChat = selectedChatID.flatMap { chats.chat($0)?.locked == true ? nil : $0 }
        }
    }

    /// Brings the app's window forward; the shell provides it.
    @ObservationIgnored public var bringToFront: () -> Void = {}
    /// Opens `chat` in a window of its own; set by the app's shell.
    @ObservationIgnored public var openChatWindow: (String) -> Void = { _ in }
    /// The backend unlinked this account and stopped after `removeAccount`;
    /// its files may go. Set by whoever keeps the accounts.
    @ObservationIgnored public var onAccountRemoved: () -> Void = {}
    /// The accounts this one is among, when there is a hub.
    @ObservationIgnored public internal(set) weak var hub: AccountHub?

    /// Transient messages for the notice banner, oldest first.
    public private(set) var notices: [Notice] = []

    /// Composer text per chat, including unsaved edits.
    public var composerText: [String: String] = [:]

    /// The message the composer replies to, per chat.
    public var replyingTo: [String: MessageRecord] = [:]

    /// Files and pasted images waiting above the composer, per chat.
    public private(set) var attachments: [String: [Attachment]] = [:] {
        didSet {
            // Kept apart so that editing a photo does not redraw the chat
            // under the editor, which only needs to know it is open.
            let chats = Set(attachments.filter { $0.value.contains(where: \.isMedia) }.keys)
            if chats != mediaEditorChats { mediaEditorChats = chats }
        }
    }

    /// Chats whose staged photos or videos have the media editor open.
    public private(set) var mediaEditorChats: Set<String> = []

    /// Photos and videos being prepared to send, per chat: counted down as
    /// each goes to upstream.
    public private(set) var preparingMedia: [String: Int] = [:]

    /// Draws the media editor's words and emoji for an export; the editor
    /// sets it, so what is sent is what was seen.
    @ObservationIgnored public var overlayRenderer: OverlayRenderer?

    /// Members picked from the `@` suggestions, per chat, until sent.
    public private(set) var composerMentions: [String: [ComposerMention]] = [:]

    /// The open chat's info is showing.
    public var infoShown: Bool { infoChat != nil }
    /// The chat whose info shows over it, in the main window or its own.
    public private(set) var infoChat: String?
    /// The group member whose page the info opened on, if any.
    public private(set) var infoPerson: String?
    /// Chats shown in windows of their own, and how many of each: they
    /// are open as the main window's chat is, for reading and notifying.
    public private(set) var windowChats: [String: Int] = [:]

    /// Chats opened from the Unread list, which stay listed there after
    /// they are read (upstream's `unread_kept`), until the list changes.
    public private(set) var keptUnread: Set<String> = []
    /// The sidebar shows the Unread list, so chats opened from it are kept.
    @ObservationIgnored public var sidebarKeepsUnread = false

    /// Something shared from another app, waiting for its chat.
    public var shareRequest: ShareRequest?

    /// The keyboard shortcuts sheet is open.
    public var shortcutsShown = false

    /// The label manager is open.
    public var labelsManagerShown = false

    /// The chat whose own theme is being chosen (from its menu).
    public var themeEditorChat: String?

    /// A sticker pack shared in a chat, being fetched or looked at.
    public var stickerPackPreview: StickerPackPreview?

    /// The group invite sheet: a link being pasted, looked up, or joined.
    public var invite: GroupInvite?

    /// The New Chat sheet is open.
    public var newChatShown = false
    /// A number is being checked with WhatsApp.
    public private(set) var newContactPending = false

    /// Groups whose name or photo change is on its way to WhatsApp.
    public private(set) var groupSaving: Set<String> = []

    /// The chat whose Create Poll sheet is open.
    public var pollComposerChat: String?
    /// A new poll is on its way.
    public private(set) var pollCreating = false

    /// Business messages whose reply is on its way.
    public private(set) var interactiveSending: Set<MessageKey> = []
    /// The list of choices open for a business message's button.
    public var interactiveList: InteractiveListRequest?

    /// Polls whose vote is on its way.
    public private(set) var pollVoting: Set<MessageKey> = []
    /// The poll whose results sheet is open.
    public var pollResults: MessageKey?

    /// The Locked folder's code sheet is showing.
    public var lockedChatsPrompt = false

    /// A chat whose clearing, deleting or locking waits for the person to confirm.
    public var chatConfirmation: ChatConfirmation?
    /// A chat whose export waits to be told how: with its media or without.
    public var exportRequest: ChatExportRequest?
    /// The chat being exported. One export runs at a time.
    public private(set) var exportingChat: String?
    /// The chat whose files and older messages are being fetched from the
    /// phone. One at a time; it goes on when its sheet is closed.
    public private(set) var phoneFetch: PhoneFetch?
    /// The sheet of `phoneFetch` is showing.
    public var phoneFetchShown = false

    /// The message whose "Message info" sheet is open. A group message's
    /// receipts are followed while it is.
    public var messageInfo: MessageKey? {
        didSet { if messageInfo != oldValue { followReceipts() } }
    }
    /// The receipts of the group message `messageInfo` shows, once they came.
    public private(set) var receipts: MessageReceiptsInfo?

    /// Messages waiting for the person to pick where to forward them.
    public private(set) var forwarding: ForwardRequest?
    /// Messages typed in the forward sheet, waiting for the forwards to
    /// their chat to leave first.
    private(set) var forwardNotes: [ForwardNote] = []

    /// The message the composer is editing, per chat.
    public private(set) var editing: [String: MessageRecord] = [:]
    /// Bumped to put the cursor back in the composer.
    public private(set) var composerFocusRequests = 0

    /// A message the timeline should scroll to; the token tells a second
    /// jump to the same message apart from the first.
    public private(set) var jump: JumpRequest?
    /// The message just jumped to, marked for a moment so the eye finds it.
    public private(set) var highlighted: MessageKey?
    /// A scroll the timeline should make once (keys, the newest-message
    /// button).
    public private(set) var timelineScroll: TimelineScrollRequest?
    /// The sidebar's chats in the order shown, for stepping through them
    /// from the keyboard; the sidebar keeps it current. Not observed: it
    /// changes with most messages, and the menu bar reads only
    /// `sidebarShortcutTitles`.
    @ObservationIgnored public var sidebarOrder: [String] = []
    /// The names of the sidebar's first nine chats, for Go to Chat (⌘1 to
    /// ⌘9). The sidebar sets them when they change, so a message does not
    /// make the menu bar again.
    public var sidebarShortcutTitles: [String] = []
    /// The message whose reaction picker is open.
    public var reactionTarget: MessageKey?
    /// Messages picked in the open chat (upstream's `selection`), for
    /// forwarding or deleting together.
    public private(set) var selection: MessageSelection?
    /// A voice message the backend refused (offline, or its quote gone),
    /// kept for the composer to send again or discard, as upstream's
    /// `unsent_voice`. It lives until then, in memory only.
    public private(set) var unsentVoice: UnsentVoice?
    /// Where the open chat's unread messages began when it was opened.
    public private(set) var unreadDivider: UnreadDivider?
    /// Bumped to put the cursor in the sidebar's search field.
    public private(set) var sidebarSearchRequests = 0
    /// Bumped to put the cursor in the open chat's search field.
    public private(set) var chatSearchFocusRequests = 0

    /// The WhatsApp account this model shows, as the bridge's roster names it.
    public let accountID: String
    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private var started = false
    @ObservationIgnored let launch = LaunchTimer()
    @ObservationIgnored private let eventStats = EventStats()
    @ObservationIgnored lazy var phoneHistory = PhoneHistory(defaults: preferences.defaults)
    /// Files the phone no longer has, so fetching a chat does not ask twice.
    @ObservationIgnored lazy var goneMedia = GoneMedia(defaults: preferences.defaults, account: accountID)
    /// Brings the link back when the network does, created on start.
    @ObservationIgnored private var networkWatch: NetworkWatch?
    @ObservationIgnored private var verbose = false
    @ObservationIgnored private let log = Logger(subsystem: "ZapFast", category: "AppModel")
    /// Chats we told the backend we are typing in, and the task that will
    /// say we stopped.
    @ObservationIgnored private var composingIn: [String: Task<Void, Never>] = [:]
    /// Downloads the person asked for and has not heard the end of.
    @ObservationIgnored private var askedDownloads: Set<MessageKey> = []
    /// Voice messages we already sent a played receipt for.
    @ObservationIgnored private var playedTold: Set<String> = []
    /// Created on start: Notification Center needs a real app bundle.
    @ObservationIgnored private var notifier: AccountNotifier?
    /// The app is in front (the lock may still hide it).
    @ObservationIgnored private var isActive = true
    /// A clicked notification's chat, opened once the app lock lifts.
    @ObservationIgnored private var openAfterUnlock: MessageKey?
    /// A video asked to play before it was here (upstream's `video_wanted`);
    /// it starts once its download lands, if its chat is still open.
    @ObservationIgnored private var videoWanted: MessageKey?
    @ObservationIgnored private var lastChatRestored = false
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
    @ObservationIgnored private var mentionsBeforeEdit: [String: [ComposerMention]?] = [:]
    @ObservationIgnored private var gifSearchTask: Task<Void, Never>?
    @ObservationIgnored private var wantedGifQuery: String?
    /// The query the sidebar's message hits should answer.
    @ObservationIgnored private var wantedMessageQuery = ""
    @ObservationIgnored private var chatSearchTask: Task<Void, Never>?
    /// The group message the backend follows receipts for.
    @ObservationIgnored private var receiptsWatch: MessageKey?

    public init(
        accountID: String = "1",
        backend: Backend? = nil,
        paths: AppPaths = .standard(),
        preferences: Preferences = Preferences(),
        accountPreferences: AccountPreferences? = nil,
        calls: CallService? = nil,
        shared: SharedServices? = nil
    ) {
        let backend = backend ?? LiveBackend(account: accountID)
        self.accountID = accountID
        self.accountPreferences = accountPreferences
            ?? AccountPreferences(account: accountID, defaults: preferences.defaults)
        self.preferences = preferences
        let session = SessionStore()
        self.session = session
        self.chats = ChatStore(session: session)
        self.conversations = ConversationStore()
        self.backend = backend
        self.paths = paths
        self.avatars = AvatarStore(send: backend.send)
        self.appLock = shared?.appLock ?? AppLock(preferences: preferences)
        self.themes = shared?.themes
            ?? ThemeStore(defaults: preferences.defaults, wallpapersFolder: paths.data.appending(path: "Wallpapers"))
        self.notifier = shared.flatMap { $0.notifier }.map { AccountNotifier(notifier: $0, account: accountID) }
        self.lockedChats = LockedChats(preferences: preferences)
        // Only the live backend's process has a WhatsApp client to call with.
        let live = backend is LiveBackend
        self.calls = CallStore(
            service: calls ?? (live ? LiveCallService(account: accountID) : PreviewCallService()),
            live: live
        )
        self.calls.onNotice = { [weak self] kind, text in self?.post(kind, text) }
        voice.onFinished = { [weak self] key in self?.continueVoice(after: key) }
        // A shared lock is for every account; whoever shares it tells them.
        if shared == nil {
            appLock.onLock = { [weak self] in self?.locked() }
            appLock.onUnlock = { [weak self] in self?.unlocked() }
        }
    }

    /// The person is looking at this account, and the lock does not hide it.
    private var isReading: Bool {
        isActive && isOnScreen && !appLock.isLocked
    }

    // MARK: Lifecycle

    public func start(verbose: Bool = false) {
        guard !started else { return }
        started = true
        // Notification Center needs a real app bundle, which only the live
        // backend runs in.
        if notifier == nil, backend is LiveBackend {
            let notifier = Notifier()
            notifier.onResponse = { [weak self] _, response in self?.handle(response) }
            notifier.requestAuthorization()
            self.notifier = AccountNotifier(notifier: notifier, account: accountID)
        }
        self.verbose = verbose
        if networkWatch == nil, backend is LiveBackend {
            let watch = NetworkWatch(
                needsReconnect: { [weak self] in
                    guard let session = self?.session else { return false }
                    return session.linkSaysLinked && !session.isConnected
                },
                reconnect: { [weak self] in self?.backend.reconnectNow() }
            )
            watch.start()
            networkWatch = watch
        }
        appLock.startIdleTimer()
        Task { [caches = paths.caches] in await MediaExport.sweepOutgoing(in: caches) }
        Task.detached(priority: .utility) { PhoneFormat.warmUp() }
        // The saved proxy is in use from the first connection on.
        if backend is LiveBackend { proxyConfigure(setting: preferences.proxy) }
        do {
            try backend.start(paths: paths, verbose: verbose) { [weak self] events in
                self?.apply(events)
            }
            launch.step("backend started")
            session.link = .starting
            if let folder = preferences.downloadFolder { backend.send(.setDownloadFolder(path: folder)) }
            if !preferences.keepChatsArchived { backend.send(.setKeepChatsArchived(keep: false)) }
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

    /// The main window's first appearance, for the launch log.
    public func mainWindowAppeared() {
        launch.step("window shown")
    }

    public func shutdown() {
        guard started else { return }
        if let selectedChatID { flushDraft(for: selectedChatID) }
        networkWatch?.stop()
        networkWatch = nil
        backend.shutdown()
        started = false
    }

    /// How the account switcher names this account: our name, else our
    /// number.
    public var accountTitle: String {
        if let account = session.account {
            if let name = account.name, !name.isEmpty { return name }
            if let number = PhoneFormat.display(id: account.id) { return number }
        }
        return isLinked ? String(localized: "WhatsApp Account") : String(localized: "New Account")
    }

    /// Our own picture, small, for the account switcher.
    public var accountPicture: URL? {
        session.account.flatMap { avatars.url(for: $0.id) }
    }

    /// Linked data exists, even while offline; upstream's `App::is_linked`.
    /// An account being added is not, until it first connects: its backend
    /// says it is connecting before it finds it has no session, and the
    /// window would show its empty chats for that moment.
    public var isLinked: Bool {
        if hub?.adding?.new == accountID { return session.isConnected }
        return session.linkSaysLinked || (!chats.chats.isEmpty && !session.isLoggedOut)
    }

    public var logFile: URL { paths.logFile }

    // MARK: Intents: link

    public func pair(phone: String) {
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty else { return }
        backend.send(.pairWithPhone(phone: digits))
    }

    /// Reconnects, or retries starting when the backend never came up. A link
    /// that is down is dialled again now, not when the library's wait ends.
    public func reconnect() {
        guard started else {
            start(verbose: verbose)
            return
        }
        backend.send(.reconnect)
        if session.linkSaysLinked, !session.isConnected { backend.reconnectNow() }
    }
    public func unlink() { backend.send(.unlink) }
    public func startOverArchive() { backend.send(.startOverArchive) }

    /// Whether the person is looking at the app; the phone keeps its push
    /// notifications while they are not.
    public func setActive(_ active: Bool) {
        isActive = active
        guard started, !appLock.isLocked, isOnScreen else { return }
        backend.send(.setOnline(online: active))
        if active, let selectedChatID { notifier?.clear(chat: selectedChatID) }
    }

    /// Whether this account is the one in the window. Another account's
    /// events still arrive, but nobody reads it: it sends no receipts, is
    /// not online, and plays nothing (upstream's `events_hidden`).
    public private(set) var isOnScreen = true

    func setOnScreen(_ shown: Bool) {
        guard shown != isOnScreen else { return }
        isOnScreen = shown
        if shown {
            guard started, !appLock.isLocked else { return }
            backend.send(.setOnline(online: isActive))
            if isActive, let selectedChatID {
                notifier?.clear(chat: selectedChatID)
                if chats.chat(selectedChatID)?.looksUnread == true { markRead(selectedChatID) }
            }
        } else {
            leaveScreen()
            if started { backend.send(.setOnline(online: false)) }
        }
    }

    // MARK: App lock

    /// While locked nothing plays or records, and the phone keeps its
    /// notifications, as nobody is reading.
    func locked() {
        leaveScreen()
        if started { backend.send(.setOnline(online: false)) }
    }

    /// What nobody looks at stops: playback, recording, the locked chats,
    /// and the sheets over the window (upstream's `clear_account_ui`).
    private func leaveScreen() {
        closeLockedChats()
        lockedChatsPrompt = false
        voice.stop()
        video.stop()
        videoWanted = nil
        if recorder.isRecording { recorder.cancel() }
        selection = nil
        reactionTarget = nil
        mediaViewer = nil
        messageInfo = nil
        forwarding = nil
        // Sheets over the whole window would show over the lock screen.
        invite = nil
        themeEditorChat = nil
        stickerPackPreview = nil
        chatConfirmation = nil
    }

    func unlocked() {
        if let key = openAfterUnlock {
            openAfterUnlock = nil
            open(notified: key)
        }
        guard started, isOnScreen else { return }
        backend.send(.setOnline(online: isActive))
        if isActive, let selectedChatID {
            notifier?.clear(chat: selectedChatID)
            if chats.chat(selectedChatID)?.looksUnread == true { markRead(selectedChatID) }
        }
    }

    /// "Forgot password?" on the lock screen: unlink, which forgets the
    /// password once WhatsApp confirms.
    public func unlinkToForgetPassword() {
        guard appLock.isLocked else { return }
        appLock.startUnlinking()
        // Every account linked here goes: the lock guards them all.
        for model in hub?.models ?? [self] { model.unlink() }
    }

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
    private func encodeMentions(_ text: String, in chat: String) -> (String, [String]) {
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

    // MARK: Intents: chat info

    /// Shows the chat's info over it, as a click on its header does, or a
    /// group member's page there, as a click on their name does. The chat's
    /// search stays open beside it.
    public func showInfo(in chat: String? = nil, person: String? = nil) {
        guard let chat = chat ?? selectedChatID else { return }
        infoChat = chat
        infoPerson = person.flatMap { session.isOurs($0) ? nil : $0 }
    }

    public func closeInfo() {
        infoChat = nil
        infoPerson = nil
    }

    // MARK: Intents: the Share menu

    /// A `zapfast-mac://share` link from the Share extension: asks which
    /// chat it goes to. Returns whether the link was one.
    @discardableResult
    public func receiveShare(_ url: URL) -> Bool {
        guard let request = ShareRequest.read(url) else { return false }
        shareRequest = request
        bringToFront()
        return true
    }

    /// Puts what was shared in `chat`'s composer, to be sent from there
    /// with a caption or a reply: files wait above the field, text joins
    /// what is typed.
    public func deliverShare(to chat: String) {
        guard let request = shareRequest else { return }
        shareRequest = nil
        selectedChatID = chat
        if !request.files.isEmpty { stage(files: request.files, in: chat) }
        if !request.text.isEmpty {
            let typed = composerText[chat] ?? ""
            composerText[chat] = typed.isEmpty ? request.text : typed + "\n" + request.text
        }
        composerFocusRequests += 1
    }

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

    // MARK: Intents: shared contacts

    /// A contact card's name, number and WhatsApp account, read as
    /// upstream's bubble reads it.
    public func sharedContact(in message: MessageRecord) -> SharedContact? {
        guard case let .contact(displayName, vcard) = message.content else { return nil }
        return ZapFastBridge.sharedContact(vcard: vcard, fallbackName: displayName)
    }

    /// The chat id of a shared contact's WhatsApp account.
    public static func chatID(ofAccount account: String) -> String {
        "\(account)@s.whatsapp.net"
    }

    /// The account is already among the contacts WhatsApp knows.
    public func isKnownContact(_ account: String) -> Bool {
        chats.contacts[Self.chatID(ofAccount: account)] != nil
    }

    /// "Message": the chat with the card's account (upstream's StartChat).
    public func chat(with contact: SharedContact) {
        guard let account = contact.account else { return }
        startChat(with: Self.chatID(ofAccount: account), name: contact.name)
    }

    /// "Add": saves the card as a contact, the name split at its first
    /// space as upstream's `split_name` does.
    public func addContact(_ contact: SharedContact) {
        guard let account = contact.account else { return }
        let name = contact.name.trimmingCharacters(in: .whitespaces)
        let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
        newContact(
            phone: account,
            first: parts.first ?? name,
            last: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        )
    }

    // MARK: Intents: group invites

    /// A link was clicked: a WhatsApp group invite opens here (upstream's
    /// rule), anything else is left to the system. Returns whether it was one.
    @discardableResult
    public func openInviteLink(_ url: URL) -> Bool {
        guard let code = groupInviteCode(url: url.absoluteString) else { return false }
        previewInvite(code: code)
        return true
    }

    /// File › Join Group with Link…: the sheet asks for the link.
    public func askForInviteLink() {
        invite = GroupInvite(code: "", state: .entering)
    }

    /// The pasted text, when it is an invite link. Returns whether it was.
    @discardableResult
    public func submitInviteLink(_ text: String) -> Bool {
        guard let code = groupInviteCode(url: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        previewInvite(code: code)
        return true
    }

    private func previewInvite(code: String) {
        invite = GroupInvite(code: code, state: .loading)
        backend.send(.previewInvite(code: code))
    }

    /// Whether the group behind the invite is one we are already in.
    public func isMember(of info: InviteInfo) -> Bool {
        chats.chat(info.id).map { !$0.left } ?? false
    }

    /// Joins, or opens the chat of a group we are already in.
    public func acceptInvite() {
        guard var current = invite, case .ready(let info) = current.state else { return }
        if isMember(of: info) {
            invite = nil
            selectedChatID = info.id
            return
        }
        current.state = .joining(info)
        invite = current
        backend.send(.joinInvite(code: current.code))
    }

    public func cancelInvite() {
        invite = nil
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

    // MARK: Intents: labels

    /// Upstream's limits and colours for labels.
    public let labelRules = ZapFastBridge.labelRules()

    /// Why a label cannot have `name`, or nil (upstream's refusals: the
    /// label limit, and a name another label already has).
    public func labelProblem(name: String, except id: String? = nil) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if id == nil, chats.labels.count >= Int(labelRules.limit) {
            return String(localized: "You have \(labelRules.limit) labels, the most ZapFast keeps.")
        }
        if chats.labels.contains(where: { $0.id != id && $0.name.lowercased() == name.lowercased() }) {
            return String(localized: "A label named “\(name)” already exists.")
        }
        return nil
    }

    public func createLabel(name: String, colorHex: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Int(labelRules.nameLimit)))
        guard !name.isEmpty else { return }
        if let problem = labelProblem(name: name) { return post(.error, problem) }
        backend.send(.createLabel(name: name, colorHex: colorHex))
    }

    public func updateLabel(_ label: LabelInfo, name: String, colorHex: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Int(labelRules.nameLimit)))
        guard !name.isEmpty, name != label.name || colorHex != label.colorHex else { return }
        if let problem = labelProblem(name: name, except: label.id) { return post(.error, problem) }
        backend.send(.updateLabel(id: label.id, name: name, colorHex: colorHex))
    }

    public func deleteLabel(_ label: LabelInfo) {
        backend.send(.deleteLabel(id: label.id))
    }

    /// Puts a label on a chat, or takes it off.
    public func toggleLabel(_ label: String, on chat: ChatSummary) {
        var worn = chat.labels
        if let index = worn.firstIndex(of: label) { worn.remove(at: index) } else { worn.append(label) }
        backend.send(.setChatLabels(chat: chat.id, labels: worn))
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

    /// Fetches a pack shared in a chat and shows it.
    public func viewStickerPack(_ message: MessageRecord) {
        guard case .stickerPack = message.content else { return }
        stickerPackPreview = StickerPackPreview(chat: message.chat, state: .loading)
        backend.send(.viewStickerPack(chat: message.chat, message: message.id))
    }

    /// Keeps the viewed pack in the picker's packs.
    public func addViewedStickerPack() {
        guard case .ready(let pack, _) = stickerPackPreview?.state else { return }
        stickerPackPreview = nil
        backend.send(.addStickerPack(dir: pack.dir, name: pack.name))
    }

    /// Starts an empty pack of our own.
    public func createStickerPack(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        backend.send(.createStickerPack(name: name))
    }

    /// Files a sticker into one of our own packs, or takes it out.
    public func setSticker(_ path: String, in pack: StickerPackInfo, member: Bool) {
        guard pack.local else { return }
        backend.send(.setStickerPack(pack: pack.dir, sticker: path, member: member))
    }

    public func deleteStickerPack(_ pack: StickerPackInfo) {
        backend.send(.deleteStickerPack(dir: pack.dir))
    }

    /// Imports a pack from a signal.art link, which the worker fetches
    /// from Signal's servers; a bad link ends with its error.
    public func importStickerPack(from link: String) {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        backend.send(.importStickerUrl(url: link))
    }

    /// Adds a pack from a `.wastickers` archive (WhatsApp's sticker apps
    /// share them) chosen in the open panel upstream shows for it.
    public func importStickerArchive() {
        backend.send(.pickStickerArchive)
    }

    /// Makes a sticker from `picture`: sent to `chat`, or without one added
    /// to Favorites. Upstream crops, scales to 512 and encodes WebP.
    public func makeSticker(
        from picture: StickerPicture,
        crop: StickerCropInfo,
        keepTransparency: Bool,
        emojis: [String],
        sendTo chat: String?
    ) {
        backend.send(.makeSticker(
            source: picture.url.path(percentEncoded: false), crop: crop,
            transparent: picture.transparent && keepTransparency, emojis: emojis, chat: chat
        ))
    }

    /// Sends one of our packs to a chat as a sticker pack message.
    public func sendStickerPack(_ pack: StickerPackInfo, in chat: String) {
        guard session.isConnected else { return }
        backend.send(.sendStickerPack(chat: chat, dir: pack.dir))
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

    // MARK: Intents: our profile

    /// Upstream's limits on our name and About.
    public static let profileNameLimit = 25
    public static let aboutLimit = 139

    /// Sends what changed, as upstream's account settings do: a blank name
    /// keeps the current one; About may be cleared.
    public func saveProfile(name: String, about: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.profileNameLimit))
        let about = String(about.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.aboutLimit))
        let account = session.account
        let changedName = (!name.isEmpty && account?.name != name) ? name : nil
        let changedAbout = ((account?.about ?? "") != about) ? about : nil
        guard changedName != nil || changedAbout != nil else { return }
        backend.send(.setProfile(name: changedName, about: changedAbout))
    }

    public func setProfilePicture(from url: URL) {
        Task {
            do {
                let jpeg = try await PictureEncoding.squareJPEG(from: url)
                backend.send(.setProfilePicture(jpeg: jpeg))
            } catch {
                post(.error, String(localized: "Could not use this picture: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: Intents: account privacy

    /// Privacy can change on the phone at any time and nothing announces
    /// it, so Settings asks again each time it shows.
    public func refreshPrivacy() {
        guard session.isConnected else { return }
        backend.send(.fetchAccountPrivacy)
    }

    /// Writes one category, showing it at once; a refusal restores the
    /// phone's value. Nothing is written offline or against stale values.
    public func setPrivacy(_ kind: PrivacyKindInfo, to choice: PrivacyChoiceInfo) {
        guard session.isConnected, privacy.isEditable,
              privacy.snapshot.beginSet(kind: kind, choice: choice) else { return }
        privacy.changed()
        backend.send(.setAccountPrivacy(kind: kind, choice: choice))
    }

    /// The account's read receipts win over the local switch: they are
    /// what the phone and the other linked devices enforce.
    private func followReceiptsPrivacy() {
        if let choice = privacy.choice(.readReceipts) {
            session.receiptsDisabled = choice != .everyone
        }
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
            id: id, fullName: name.full, firstName: name.short, toPhone: accountPreferences.saveContactsToPhone
        ))
    }

    // MARK: Intents: polls

    /// Sends a new poll once upstream's rules accept it, one at a time.
    public func createPoll(_ draft: PollDraftInfo, in chat: String) {
        guard pollDraftProblem(draft: draft) == nil, session.isConnected, !pollCreating else { return }
        pollCreating = true
        backend.send(.createPoll(chat: chat, draft: draft))
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
    private func followForwards(_ messages: [MessageRecord]) {
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
    }

    public func cancelForward() {
        forwarding = nil
    }

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

    // MARK: Intents: attachments

    /// Stages files above the composer (picked, dropped or pasted); they go
    /// with the next send. An edit in progress gives way to them.
    public func stage(files urls: [URL], in chat: String) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        stage(files.map { Attachment(.file($0)) }, in: chat)
    }

    /// Stages a pasted picture.
    public func stage(image: PastedImage, in chat: String) {
        stage([Attachment(.image(image))], in: chat)
    }

    /// A photo or video opens the media editor over the chat, as on the
    /// phone; the text typed so far becomes the first one's caption.
    private func stage(_ added: [Attachment], in chat: String) {
        cancelEditing(in: chat)
        var added = added
        if !isEditingMedia(in: chat), added.contains(where: \.isMedia) {
            let text = composerText[chat] ?? ""
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let first = (attachments[chat] ?? []).isEmpty ? 0 : nil
                if let first {
                    added[first].caption = text
                } else {
                    attachments[chat]?[0].caption = text
                }
                composerText[chat] = ""
            }
        }
        attachments[chat, default: []] += added
        composerFocusRequests += 1
    }

    public func removeAttachment(_ id: Attachment.ID, in chat: String) {
        guard let index = attachments[chat]?.firstIndex(where: { $0.id == id }) else { return }
        let removed = attachments[chat]!.remove(at: index)
        if attachments[chat]?.isEmpty == true {
            attachments[chat] = nil
            // The last caption goes back to the field, as the text came.
            restoreCaption(removed.caption, in: chat)
        } else if index == 0, !removed.caption.isEmpty, attachments[chat]![0].caption.isEmpty {
            attachments[chat]![0].caption = removed.caption
        }
    }

    // MARK: Intents: the media editor

    /// Photos or videos are staged, so the media editor shows.
    public func isEditingMedia(in chat: String) -> Bool {
        mediaEditorChats.contains(chat)
    }

    public func setEdit(_ edit: MediaEdit, for id: Attachment.ID, in chat: String) {
        guard let index = attachments[chat]?.firstIndex(where: { $0.id == id }) else { return }
        attachments[chat]![index].edit = edit
    }

    public func setCaption(_ caption: String, for id: Attachment.ID, in chat: String) {
        guard let index = attachments[chat]?.firstIndex(where: { $0.id == id }) else { return }
        attachments[chat]![index].caption = caption
    }

    /// Closes the editor without sending. The first caption returns to the
    /// field, so nothing typed is lost.
    public func discardAttachments(in chat: String) {
        guard let staged = attachments.removeValue(forKey: chat) else { return }
        restoreCaption(staged.first(where: { !$0.caption.isEmpty })?.caption ?? "", in: chat)
    }

    private func restoreCaption(_ caption: String, in chat: String) {
        guard !caption.isEmpty, (composerText[chat] ?? "").isEmpty else { return }
        composerText[chat] = caption
    }

    /// Sends what the editor holds, each with its own caption and the
    /// reply on the first, in order. Photos are redrawn at the chosen
    /// quality and videos re-encoded first, off the main thread; a
    /// document among them goes as it is.
    public func sendMedia(in chat: String) {
        guard let staged = attachments.removeValue(forKey: chat), !staged.isEmpty else { return }
        let quality = preferences.mediaQuality
        let picked = composerMentions.removeValue(forKey: chat) ?? []
        let participants = chats.chat(chat)?.participants ?? []
        var quoting = replyingTo.removeValue(forKey: chat)?.id
        stopComposing(in: chat)
        preparingMedia[chat, default: 0] += staged.count
        let outgoing = MediaExport.outgoingDirectory(in: paths.caches)
        Task {
            for attachment in staged {
                defer {
                    preparingMedia[chat, default: 1] -= 1
                    if preparingMedia[chat] == 0 { preparingMedia[chat] = nil }
                }
                let path: String
                do {
                    path = try await prepare(attachment, quality: quality, outgoing: outgoing)
                } catch {
                    post(.error, error.localizedDescription)
                    continue
                }
                let caption = attachment.caption.trimmingCharacters(in: .whitespacesAndNewlines)
                let (encoded, mentions) = MentionEncoding.encode(caption, picked: picked, participants: participants)
                backend.send(.sendFiles(
                    chat: chat, paths: [path], caption: encoded.isEmpty ? nil : encoded,
                    mentions: mentions, quoting: quoting
                ))
                quoting = nil
            }
        }
    }

    /// The file upstream sends for an attachment.
    private func prepare(_ attachment: Attachment, quality: MediaQuality, outgoing: URL) async throws -> String {
        let edit = attachment.edit
        // A file prepared before (a refused send come back) goes as it is.
        let prepared = attachment.fileURL.map { $0.deletingLastPathComponent().standardizedFileURL == outgoing.standardizedFileURL } ?? false
        switch attachment.media {
        case .none:
            guard let url = attachment.fileURL else { throw MediaExport.Failure.unreadable }
            return url.path(percentEncoded: false)
        case .video:
            guard let url = attachment.fileURL else { throw MediaExport.Failure.noVideo }
            if edit.isEmpty, quality == .hd || prepared { return url.path(percentEncoded: false) }
            let info = try await MediaExport.videoInfo(url)
            let overlays = renderOverlays(edit.overlays, longSide: max(info.size.width, info.size.height))
            let destination = try outgoingFile(in: outgoing, extension: "mp4")
            try await MediaExport.exportVideo(url, edit: edit, overlays: overlays, quality: quality, to: destination)
            return destination.path(percentEncoded: false)
        case .photo:
            if prepared, edit.isEmpty, let url = attachment.fileURL { return url.path(percentEncoded: false) }
            let plan: MediaExport.PhotoPlan
            switch attachment.kind {
            case .file(let url):
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw MediaExport.Failure.unreadable }
                plan = try await MediaExport.planPhoto(source, edit: edit, quality: quality)
            case .image(let image):
                guard let picture = image.cgImage else { throw MediaExport.Failure.unreadable }
                plan = MediaExport.planPhoto(picture, edit: edit, quality: quality)
            }
            let overlays = renderOverlays(edit.overlays, longSide: max(plan.canvas.width, plan.canvas.height))
            let data = try await MediaExport.renderPhoto(plan, edit: edit, overlays: overlays, quality: quality)
            let destination = try outgoingFile(in: outgoing, extension: "jpg")
            try data.write(to: destination)
            return destination.path(percentEncoded: false)
        }
    }

    private func renderOverlays(_ overlays: [MediaOverlay], longSide: CGFloat) -> [RenderedOverlay] {
        guard let overlayRenderer else { return [] }
        return overlays.compactMap { overlay in
            overlayRenderer(overlay, longSide).map { RenderedOverlay(overlay: overlay, image: $0) }
        }
    }

    private func outgoingFile(in directory: URL, extension ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(UUID().uuidString).\(ext)")
    }

    /// Upstream's `send_pending`: the caption, its mentions and the reply
    /// travel with the first attachment; pasted images go one by one, the
    /// files together.
    private func sendAttachments(in chat: String, caption text: String) {
        guard let staged = attachments.removeValue(forKey: chat), !staged.isEmpty else { return }
        let (encoded, encodedMentions) = encodeMentions(text, in: chat)
        var caption = encoded.isEmpty ? nil : encoded
        var mentions = encodedMentions
        var quoting = replyingTo.removeValue(forKey: chat)?.id
        composerText[chat] = ""
        chats.setDraft("", for: chat)
        backend.send(.saveDraft(chat: chat, text: ""))
        stopComposing(in: chat)
        var files: [String] = []
        for attachment in staged {
            switch attachment.kind {
            case .image(let image):
                backend.send(.sendImage(
                    chat: chat, width: image.width, height: image.height, rgba: image.rgba,
                    caption: caption, mentions: mentions, quoting: quoting
                ))
                caption = nil
                mentions = []
                quoting = nil
            case .file(let url):
                files.append(url.path(percentEncoded: false))
            }
        }
        if !files.isEmpty {
            backend.send(.sendFiles(chat: chat, paths: files, caption: caption, mentions: mentions, quoting: quoting))
        }
    }

    /// The composer changed: tell the chat we are typing, and that we
    /// stopped once the keys have been quiet for a few seconds.
    /// Completions for a `:shortcode` typed in the composer.
    public func emojiSuggestions(for query: String) -> [EmojiSuggestionInfo] {
        ZapFastBridge.emojiSuggestions(query: query, recent: preferences.recentEmoji)
    }

    // MARK: Intents: text size

    public static let textScales = stride(from: 0.8, through: 1.6, by: 0.1).map { ($0 * 10).rounded() / 10 }

    /// View › Bigger / Smaller: a tenth at a time, as upstream's zoom steps.
    public func changeTextSize(bigger: Bool) {
        let scales = Self.textScales
        let current = scales.firstIndex { abs($0 - preferences.textScale) < 0.05 } ?? scales.firstIndex(of: 1)!
        let next = min(max(current + (bigger ? 1 : -1), 0), scales.count - 1)
        preferences.textScale = scales[next]
    }

    public func resetTextSize() {
        preferences.textScale = 1
    }

    public var canMakeTextBigger: Bool { preferences.textScale < Self.textScales.last! - 0.05 }
    public var canMakeTextSmaller: Bool { preferences.textScale > Self.textScales.first! + 0.05 }

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
    private func restoreLastChat() {
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

    private func stopComposing(in chat: String) {
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
        video.stop()
        let opus = media.mime.contains("ogg") || media.mime.contains("opus")
        let speed = voiceNote ? preferences.voiceSpeed : 1
        Task { await voice.toggle(key, url: url, opus: opus, speed: speed) }
        if voiceNote, !message.fromMe, playedTold.insert(message.id).inserted {
            backend.send(.markPlayed(
                chat: message.chat,
                message: message.id,
                sender: message.sender,
                receipts: accountPreferences.sendReadReceipts
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
        video.stop()
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

    /// Pauses the take, letting go of the microphone, or goes on with it.
    public func toggleRecordingPause() {
        if recorder.isPaused {
            if !recorder.resume() {
                post(.error, String(localized: "ZapFast couldn't use the microphone to go on recording."))
            }
        } else {
            recorder.pause()
        }
    }

    /// Plays a paused take back, or stops it.
    public func toggleRecordingPreview() {
        recorder.togglePreview()
    }

    /// A take this long asks before it is thrown away, so a stray Escape
    /// cannot lose it.
    public static let discardAskAfter: TimeInterval = 10

    /// Sends the refused voice message again, with the reply if one is set.
    public func resendVoice(in chat: String) {
        guard let unsent = unsentVoice, unsent.chat == chat else { return }
        unsentVoice = nil
        let quoting = replyingTo.removeValue(forKey: chat)?.id
        backend.send(.sendVoice(chat: chat, samples: unsent.samples, quoting: quoting))
    }

    public func discardUnsentVoice() {
        unsentVoice = nil
    }

    // MARK: Intents: videos

    /// Plays or pauses a video inside its message, downloading it first if
    /// needed; one plays at a time, and voice playback stops for it.
    public func playVideo(_ message: MessageRecord) {
        guard case .video = message.content else { return }
        guard let url = message.mediaURL else {
            videoWanted = MessageKey(chat: message.chat, message: message.id)
            download(message)
            return
        }
        videoWanted = nil
        voice.stop()
        video.toggle(MessageKey(chat: message.chat, message: message.id), url: url)
    }

    /// A playing video scrolled out of view: it pauses, as upstream's does.
    public func videoHidden(_ message: MessageRecord) {
        video.pause(MessageKey(chat: message.chat, message: message.id))
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
        guard isSticker || accountPreferences.autoDownload else { return }
        guard conversations.download(MessageKey(chat: message.chat, message: message.id)) == nil else { return }
        download(message, automatic: true)
    }

    /// Asks once a session for a document's page preview, which WhatsApp
    /// keeps apart from the small inline one (if any): it shows before the
    /// file is here, and arrives as the message updated. Asked only while
    /// connected, so a chat opened before the link is up asks again later.
    public func fetchPreview(_ message: MessageRecord) {
        guard case .document = message.content, (message.thumbnail?.count ?? 0) < Self.sharpPreviewBytes,
              case .connected = session.link,
              previewsAsked.insert(MessageKey(chat: message.chat, message: message.id)).inserted else { return }
        backend.send(.fetchPreview(chat: message.chat, message: message.id))
    }

    /// A kept preview at least this large is already the sharp one, as the
    /// worker judges it.
    static let sharpPreviewBytes = 10_000
    @ObservationIgnored private var previewsAsked: Set<MessageKey> = []

    /// Sends a reaction; an empty one takes ours back. Each one sent counts
    /// towards the quick reactions, as upstream's `Action::React` does.
    public func react(_ emoji: String, to message: MessageRecord) {
        reactionTarget = nil
        backend.send(.react(chat: message.chat, message: message.id, emoji: emoji))
        guard !emoji.isEmpty else { return }
        var uses = preferences.reactionEmoji
        let count = (uses.first { $0.emoji == emoji }?.count ?? 0) &+ 1
        uses.removeAll { $0.emoji == emoji }
        uses.insert(ReactionUse(emoji: emoji, count: count), at: 0)
        // Stable: among equals the latest stays first.
        uses = uses.enumerated().sorted { ($0.element.count, -$0.offset) > ($1.element.count, -$1.offset) }.map(\.element)
        preferences.reactionEmoji = Array(uses.prefix(36))
        rememberEmoji(emoji)
    }

    /// Six to offer at once, most used first, and ours if it is not among them.
    public func quickReactions(for message: MessageRecord) -> [String] {
        ZapFastBridge.quickReactions(
            preferred: preferences.reactionEmoji.map(\.emoji),
            mine: message.reactions.first(where: \.fromMe)?.emoji
        )
    }

    // MARK: Intents: keyboard

    public func scrollTimeline(_ kind: TimelineScroll) {
        guard selectedChatID != nil else { return }
        timelineScroll = TimelineScrollRequest(kind: kind)
    }

    /// Opens the chat above or below the open one in the sidebar, wrapping
    /// around, as upstream's Alt+↑ / Alt+↓ do; with none open, the first.
    public func selectAdjacentChat(forward: Bool) {
        let order = sidebarOrder
        guard !order.isEmpty else { return }
        let next = if let current = selectedChatID, let index = order.firstIndex(of: current) {
            order[(index + (forward ? 1 : order.count - 1)) % order.count]
        } else {
            order[0]
        }
        // Stepping through the Unread list must not shift it underfoot.
        keepUnread(next)
        selectedChatID = next
    }

    /// ⌘1 to ⌘9: the chat at that place in the sidebar, as Messages does.
    public func selectChat(atSidebarPlace place: Int) {
        guard sidebarOrder.indices.contains(place) else { return }
        let chat = sidebarOrder[place]
        keepUnread(chat)
        selectedChatID = chat
    }

    /// A chat opened from the sidebar: kept while it shows the Unread list.
    public func keepUnread(_ chat: String) {
        guard sidebarKeepsUnread else { return }
        keptUnread.insert(chat)
    }

    /// The sidebar changed its filter, label or folder.
    public func forgetKeptUnread() {
        keptUnread = []
    }

    /// Upstream's "Mute all channels" / "Unmute all channels".
    public var allChannelsMuted: Bool {
        chats.channelCount > 0 && chats.mutedChannelCount == chats.channelCount
    }

    public func muteAllChannels(_ mute: Bool) {
        for channel in chats.channels where chats.isMuted(channel) != mute {
            setMuted(until: mute ? 0 : nil, chat: channel.id)
        }
    }

    /// Puts the cursor in the composer (upstream's Ctrl+L).
    public func focusComposer() {
        guard selectedChatID != nil else { return }
        composerFocusRequests += 1
    }

    // MARK: Intents: the media viewer

    /// A photo or video open in the media viewer over the chat.
    public var mediaViewer: MediaViewerRequest?

    /// Opens a photo or video in the viewer, which plays a video itself,
    /// so the one playing in its bubble stops.
    public func openMediaViewer(_ message: MessageRecord) {
        guard MediaGallery.kind(of: message) != nil else { return }
        video.stop()
        mediaViewer = MediaViewerRequest(chat: message.chat, message: message.id)
    }

    public func closeMediaViewer() {
        mediaViewer = nil
    }

    public func showReactionPicker(for message: MessageRecord) {
        reactionTarget = MessageKey(chat: message.chat, message: message.id)
    }

    public func deleteForEveryone(_ message: MessageRecord) {
        backend.send(.revoke(chat: message.chat, id: message.id))
    }

    public func deleteForMe(_ message: MessageRecord) {
        backend.send(.deleteLocal(chat: message.chat, id: message.id))
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
        guard conversation.message(message.id) != nil else { return }
        guard !conversation.fetchingPhone else {
            post(.info, String(localized: "History is already being requested for this chat"))
            return
        }
        conversations.markFetchingPhone(message.chat)
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
    private func followReceipts() {
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
        case .clear, .delete: break
        }
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
    private func fetchOlder(chat: String) {
        phoneHistory.asking(chat, holding: conversations.conversation(chat).messages.count)
        backend.send(.fetchOlder(chat: chat))
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
    /// and puts the cursor in its field. The info over the chat closes.
    public func openChatSearch(in chat: String? = nil) {
        guard let chat = chat ?? selectedChatID else { return }
        closeInfo()
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
        askChatSearch(current, wait: true)
    }

    /// Keeps the in-chat search to one day, or lifts that with nil; asked
    /// at once, since a click is not typing.
    public func setChatSearchDay(_ day: Date?, calendar: Calendar = .current) {
        guard var current = search.chat else { return }
        if let day, let interval = calendar.dateInterval(of: .day, for: day) {
            current.day = interval.start
            current.dayBounds = (Int64(interval.start.timeIntervalSince1970), Int64(interval.end.timeIntervalSince1970))
        } else {
            current.day = nil
            current.dayBounds = nil
        }
        askChatSearch(current, wait: false)
    }

    private func askChatSearch(_ search: ChatSearch, wait: Bool) {
        var current = search
        chatSearchTask?.cancel()
        guard current.isAsking else {
            current.hits = []
            current.truncated = false
            current.pending = false
            current.selected = nil
            self.search.chat = current
            return
        }
        current.pending = true
        self.search.chat = current
        let chat = current.chat, query = current.trimmedQuery, bounds = current.dayBounds
        chatSearchTask = Task { [weak self] in
            if wait { try? await Task.sleep(for: Self.searchDelay) }
            guard !Task.isCancelled else { return }
            self?.backend.send(.searchChatMessages(chat: chat, query: query, from: bounds?.from, until: bounds?.until))
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

    /// Scrolls to the message a reply quotes, as clicking a quote does
    /// upstream. A quote of a message the archive never had ends with the
    /// backend saying so.
    public func showQuoted(in message: MessageRecord) {
        guard let quoted = message.quoted, !quoted.id.isEmpty else { return }
        reveal(MessageKey(chat: message.chat, message: quoted.id))
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
    private func resolveUnreadDivider() {
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
            eventStats.measure(event) { apply(event) }
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
        case let .chatHits(chat, query, from, until, messages, truncated):
            search.applyChatHits(
                chat: chat, query: query, from: from, until: until, messages: messages, truncated: truncated
            )
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
                   let record = conversations.conversation(chat).message(message) {
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
            if let quoting, replyingTo[chat] == nil, let message = conversations.conversation(chat).message(quoting) {
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
            chats.clear()
            conversations.clear()
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

    // MARK: Notifications (upstream's `maybe_notify`)

    private func maybeNotify(chat id: String, message: MessageRecord) {
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

/// Clearing or deleting a chat, waiting to be confirmed.
public struct ChatConfirmation: Identifiable, Equatable, Sendable {
    public enum Action: Sendable { case clear, delete, lock }
    public var id: String { chat }
    public let chat: String
    public let action: Action
}

/// A chat's export, waiting to be told how.
public struct ChatExportRequest: Identifiable, Equatable, Sendable {
    public var id: String { chat }
    public let chat: String
}

/// A business message's list of choices, open for one of its buttons.
public struct InteractiveListRequest: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let key: MessageKey
    public let button: Int
}

/// A shared sticker pack being fetched, shown, or that failed to open.
public struct StickerPackPreview: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case loading
        case ready(pack: StickerPackInfo, publisher: String)
        case failed(String)
    }

    public let id = UUID()
    /// The chat it was shared in, where its stickers can be sent.
    public let chat: String
    public internal(set) var state: State
}

public struct MessageSelection: Equatable, Sendable {
    public let chat: String
    /// In chat order.
    public internal(set) var ids: [String]
    /// The last message clicked, where a Shift-click range starts.
    var anchor: String
}

/// A drag across messages: where it began, what was picked then, and whether
/// it picks what it passes over or puts it back. The timeline keeps it for
/// the length of the drag.
public struct MessageSweep: Sendable {
    let chat: String
    let anchor: String
    let base: Set<String>
    let adds: Bool
}

/// The selected messages for the share menu.
public struct SelectionShare: Equatable, Sendable {
    public let text: String?
    public let files: [URL]

    public var isEmpty: Bool { text == nil && files.isEmpty }
}

public struct UnsentVoice: Equatable, Sendable {
    public let chat: String
    public let samples: [Float]

    /// Whole seconds, at least one, as upstream's strip rounds them.
    public var seconds: Int {
        max(1, Int((Double(samples.count) / Double(voiceSampleRate())).rounded()))
    }
}

/// Upstream's `UnreadDivider`: how many messages were unread when the chat
/// was opened, and the first of them once its page is loaded.
public struct UnreadDivider: Equatable, Sendable {
    public let chat: String
    public let count: UInt32
    public internal(set) var message: String?
}

public enum TimelineScroll: Sendable {
    case pageUp, pageDown, top, bottom
}

public struct TimelineScrollRequest: Equatable, Sendable {
    public let kind: TimelineScroll
    public let token = UUID()
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
