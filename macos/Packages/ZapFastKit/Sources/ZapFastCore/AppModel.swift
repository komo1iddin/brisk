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
            protectOpenConversations()
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
    public internal(set) var notices: [Notice] = []

    /// Composer text per chat, including unsaved edits.
    public var composerText: [String: String] = [:]

    /// The message the composer replies to, per chat.
    public var replyingTo: [String: MessageRecord] = [:]

    /// Files and pasted images waiting above the composer, per chat.
    public internal(set) var attachments: [String: [Attachment]] = [:] {
        didSet {
            // Kept apart so that editing a photo does not redraw the chat
            // under the editor, which only needs to know it is open.
            let chats = Set(attachments.filter { $0.value.contains(where: \.isMedia) }.keys)
            if chats != mediaEditorChats { mediaEditorChats = chats }
        }
    }

    /// Chats whose staged photos or videos have the media editor open.
    public internal(set) var mediaEditorChats: Set<String> = []

    /// Photos and videos being prepared to send, per chat: counted down as
    /// each goes to upstream.
    public internal(set) var preparingMedia: [String: Int] = [:]

    /// Draws the media editor's words and emoji for an export; the editor
    /// sets it, so what is sent is what was seen.
    @ObservationIgnored public var overlayRenderer: OverlayRenderer?

    /// Members picked from the `@` suggestions, per chat, until sent.
    public internal(set) var composerMentions: [String: [ComposerMention]] = [:]

    /// The open chat's info is showing.
    public var infoShown: Bool { infoChat != nil }
    /// The chat whose info shows over it, in the main window or its own.
    public internal(set) var infoChat: String?
    /// The group member whose page the info opened on, if any.
    public internal(set) var infoPerson: String?
    /// Chats shown in windows of their own, and how many of each: they
    /// are open as the main window's chat is, for reading and notifying.
    public internal(set) var windowChats: [String: Int] = [:] {
        didSet { protectOpenConversations() }
    }

    /// Chats opened from the Unread list, which stay listed there after
    /// they are read (upstream's `unread_kept`), until the list changes.
    public internal(set) var keptUnread: Set<String> = []
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
    public internal(set) var newContactPending = false

    /// Groups whose name or photo change is on its way to WhatsApp.
    public internal(set) var groupSaving: Set<String> = []

    /// The chat whose Create Poll sheet is open.
    public var pollComposerChat: String?
    /// A new poll is on its way.
    public internal(set) var pollCreating = false

    /// Business messages whose reply is on its way.
    public internal(set) var interactiveSending: Set<MessageKey> = []
    /// The list of choices open for a business message's button.
    public var interactiveList: InteractiveListRequest?

    /// Polls whose vote is on its way.
    public internal(set) var pollVoting: Set<MessageKey> = []
    /// The poll whose results sheet is open.
    public var pollResults: MessageKey?

    /// The Locked folder's code sheet is showing.
    public var lockedChatsPrompt = false

    /// A chat whose clearing, deleting or locking waits for the person to confirm.
    public var chatConfirmation: ChatConfirmation?
    /// A message whose deleting waits for the person to confirm, as upstream's
    /// `ConfirmDeleteMessage`: both ways reach the phone and cannot be undone.
    public var messageDeletion: MessageDeletion?
    /// A chat whose export waits to be told how: with its media or without.
    public var exportRequest: ChatExportRequest?
    /// The chat being exported. One export runs at a time.
    public internal(set) var exportingChat: String?
    /// The chat whose files and older messages are being fetched from the
    /// phone. One at a time; it goes on when its sheet is closed.
    public internal(set) var phoneFetch: PhoneFetch?
    /// The sheet of `phoneFetch` is showing.
    public var phoneFetchShown = false

    /// The message whose "Message info" sheet is open. A group message's
    /// receipts are followed while it is.
    public var messageInfo: MessageKey? {
        didSet { if messageInfo != oldValue { followReceipts() } }
    }
    /// The receipts of the group message `messageInfo` shows, once they came.
    public internal(set) var receipts: MessageReceiptsInfo?

    /// Messages waiting for the person to pick where to forward them.
    public internal(set) var forwarding: ForwardRequest?
    /// Messages typed in the forward sheet, waiting for the forwards to
    /// their chat to leave first.
    var forwardNotes: [ForwardNote] = []

    /// The message the composer is editing, per chat.
    public internal(set) var editing: [String: MessageRecord] = [:]
    /// Bumped to put the cursor back in the composer.
    public internal(set) var composerFocusRequests = 0

    /// A message the timeline should scroll to; the token tells a second
    /// jump to the same message apart from the first.
    public internal(set) var jump: JumpRequest?
    /// The message just jumped to, marked for a moment so the eye finds it.
    public internal(set) var highlighted: MessageKey?
    /// A scroll the timeline should make once (keys, the newest-message
    /// button).
    public internal(set) var timelineScroll: TimelineScrollRequest?
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
    public internal(set) var selection: MessageSelection?
    /// A voice message the backend refused (offline, or its quote gone),
    /// kept for the composer to send again or discard, as upstream's
    /// `unsent_voice`. It lives until then, in memory only.
    public internal(set) var unsentVoice: UnsentVoice?
    /// Where the open chat's unread messages began when it was opened.
    public internal(set) var unreadDivider: UnreadDivider?
    /// Bumped to put the cursor in the sidebar's search field.
    public internal(set) var sidebarSearchRequests = 0
    /// Bumped by each message the person sends: the chat list goes to the
    /// top, where the chat moves (upstream's `follow_sent_chat`).
    public internal(set) var sentChatFollows = 0
    /// Bumped to put the cursor in the open chat's search field.
    public internal(set) var chatSearchFocusRequests = 0

    /// The WhatsApp account this model shows, as the bridge's roster names it.
    public let accountID: String
    @ObservationIgnored let backend: Backend
    @ObservationIgnored let paths: AppPaths
    @ObservationIgnored var started = false
    @ObservationIgnored let launch = LaunchTimer()
    @ObservationIgnored let eventStats = EventStats()
    @ObservationIgnored lazy var phoneHistory = PhoneHistory(defaults: preferences.defaults)
    /// Files the phone no longer has, so fetching a chat does not ask twice.
    @ObservationIgnored lazy var goneMedia = GoneMedia(defaults: preferences.defaults, account: accountID)
    /// Brings the link back when the network does, created on start.
    @ObservationIgnored private var networkWatch: NetworkWatch?
    @ObservationIgnored var verbose = false
    @ObservationIgnored let log = Logger(subsystem: "ZapFast", category: "AppModel")
    /// Chats we told the backend we are typing in, and the task that will
    /// say we stopped.
    @ObservationIgnored var composingIn: [String: Task<Void, Never>] = [:]
    /// Downloads the person asked for and has not heard the end of.
    @ObservationIgnored var askedDownloads: Set<MessageKey> = []
    /// Voice messages we already sent a played receipt for.
    @ObservationIgnored var playedTold: Set<String> = []
    /// Created on start: Notification Center needs a real app bundle.
    @ObservationIgnored var notifier: AccountNotifier?
    /// The app is in front (the lock may still hide it).
    @ObservationIgnored var isActive = true
    /// A clicked notification's chat, opened once the app lock lifts.
    @ObservationIgnored var openAfterUnlock: MessageKey?
    /// A video asked to play before it was here (upstream's `video_wanted`);
    /// it starts once its download lands, if its chat is still open.
    @ObservationIgnored var videoWanted: MessageKey?
    @ObservationIgnored var lastChatRestored = false
    /// A jump waiting for its message to load, and whether the archive was
    /// already asked for the pages up to it.
    @ObservationIgnored var pendingJump: MessageKey?
    @ObservationIgnored var jumpAskedArchive = false
    @ObservationIgnored var highlightTask: Task<Void, Never>?
    @ObservationIgnored var messageSearchTask: Task<Void, Never>?
    /// Polls whose earlier votes were already asked of the phone; the
    /// backend keeps retrying on its own after that.
    @ObservationIgnored var pollRefreshAsked: Set<MessageKey> = []
    /// What the composer held before an edit took it over, per chat.
    @ObservationIgnored var textBeforeEdit: [String: String] = [:]
    @ObservationIgnored var mentionsBeforeEdit: [String: [ComposerMention]?] = [:]
    @ObservationIgnored var gifSearchTask: Task<Void, Never>?
    @ObservationIgnored var wantedGifQuery: String?
    /// The query the sidebar's message hits should answer.
    @ObservationIgnored var wantedMessageQuery = ""
    @ObservationIgnored var chatSearchTask: Task<Void, Never>?
    /// The group message the backend follows receipts for.
    @ObservationIgnored var receiptsWatch: MessageKey?

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
            live: live, media: shared?.callMedia
        )
        self.calls.setLocked(appLock.isLocked)
        self.calls.onNotice = { [weak self] kind, text in self?.post(kind, text) }
        voice.onFinished = { [weak self] key in self?.continueVoice(after: key) }
        // A shared lock is for every account; whoever shares it tells them.
        if shared == nil {
            appLock.onLock = { [weak self] in self?.locked() }
            appLock.onUnlock = { [weak self] in self?.unlocked() }
        }
    }

    /// The person is looking at this account, and the lock does not hide it.
    var isReading: Bool {
        isActive && isOnScreen && !appLock.isLocked
    }

    /// Whether this account is the one in the window. Another account's
    /// events still arrive, but nobody reads it: it sends no receipts, is
    /// not online, and plays nothing (upstream's `events_hidden`).
    public internal(set) var isOnScreen = true

    /// Upstream's limits and colours for labels.
    public let labelRules = ZapFastBridge.labelRules()

    /// When something was last sent from this window (the composer, a
    /// sticker, a poll), so the timeline can fly our next message in from
    /// the composer rather than as one sent from the phone.
    @ObservationIgnored public internal(set) var lastSentHere: Date?

    @ObservationIgnored var previewsAsked: Set<MessageKey> = []

    /// A photo or video open in the media viewer over the chat.
    public var mediaViewer: MediaViewerRequest?

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
        calls.shutdown()
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

    /// This account's message archive, in upstream's account folder.
    public var archiveFile: URL {
        paths.data.appending(path: "State/accounts/\(accountID)/archive.db")
    }

    // MARK: App lock

    /// Locking stops message playback/recording and call video. Existing
    /// call audio can continue, while the phone keeps its notifications.
    func locked() {
        calls.setLocked(true)
        leaveScreen()
        if started { backend.send(.setOnline(online: false)) }
    }

    /// What nobody looks at stops: playback, recording, the locked chats,
    /// and the sheets over the window (upstream's `clear_account_ui`).
    func leaveScreen() {
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
        messageDeletion = nil
    }

    func unlocked() {
        calls.setLocked(false)
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

}
