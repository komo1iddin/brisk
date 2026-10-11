import Foundation
import Observation
import OSLog
import ZapFastBridge

/// What every account's model shares: one app lock, one set of themes and
/// wallpapers, and the process's notifier.
public struct SharedServices {
    public let appLock: AppLock
    public let themes: ThemeStore
    public let notifier: Notifier?
    public let callMedia: CallMediaCoordinator

    public init(appLock: AppLock, themes: ThemeStore, notifier: Notifier?, callMedia: CallMediaCoordinator = CallMediaCoordinator()) {
        self.appLock = appLock
        self.themes = themes
        self.notifier = notifier
        self.callMedia = callMedia
    }
}

/// The WhatsApp accounts linked on this Mac, each with a model of its own,
/// as upstream's `App` keeps an `Account` per backend. One is on screen;
/// the others keep running, notify, and count their unread chats, but are
/// not read (no receipts, not online, nothing plays).
///
/// The bridge's `AccountManager` keeps the roster and the folders. Adding an
/// account puts a new one on screen to be linked; leaving it before it is
/// linked removes it again. Removing an account unlinks it, waits for its
/// backend to stop, then deletes its files; the last one is only unlinked.
@MainActor
@Observable
public final class AccountHub {
    /// The accounts' models, in the roster's order.
    public private(set) var models: [AppModel]
    /// The account in the window.
    public private(set) var active: AppModel
    public let preferences: Preferences
    /// Being added and not linked yet, with the account that was on screen.
    public private(set) var adding: (new: String, before: String)?

    @ObservationIgnored public let shared: SharedServices
    /// Called after another account came on screen, to show it.
    @ObservationIgnored public var onActiveChanged: (AppModel) -> Void = { _ in }
    /// Called for every model made after the first, before it starts.
    @ObservationIgnored public var onModelAdded: (AppModel) -> Void = { _ in }
    /// Called when a removed account's model has stopped, to close its windows.
    @ObservationIgnored public var onModelRemoved: (AppModel) -> Void = { _ in }
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let live: Bool
    @ObservationIgnored private var verbose = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private let log = Logger(subsystem: "ZapFast", category: "Accounts")

    /// The live accounts, starting with the one the roster puts on screen.
    public init(paths: AppPaths = .standard(), preferences: Preferences = Preferences()) {
        self.paths = paths
        self.preferences = preferences
        live = true
        let notifier = Notifier()
        shared = SharedServices(
            appLock: AppLock(preferences: preferences),
            themes: ThemeStore(defaults: preferences.defaults, wallpapersFolder: paths.data.appending(path: "Wallpapers")),
            notifier: notifier,
            callMedia: .shared
        )
        let first = AppModel(
            accountID: LiveAccounts.activeAccount(paths: paths), paths: paths, preferences: preferences, shared: shared
        )
        models = [first]
        active = first
        wire()
        hook(first)
    }

    /// One model that is not live: previews, the benchmark, tests.
    public init(model: AppModel) {
        paths = .standard()
        preferences = model.preferences
        live = false
        shared = SharedServices(appLock: model.appLock, themes: model.themes, notifier: nil, callMedia: model.calls.media)
        models = [model]
        active = model
    }

    /// Several models that are not live and share `shared`, for tests.
    init(models: [AppModel], shared: SharedServices) {
        paths = .standard()
        preferences = models[0].preferences
        live = false
        self.shared = shared
        self.models = models
        active = models[0]
        wire()
        for model in models {
            hook(model)
            if model !== active { model.setOnScreen(false) }
        }
    }

    private func wire() {
        shared.appLock.onLock = { [weak self] in self?.models.forEach { $0.locked() } }
        shared.appLock.onUnlock = { [weak self] in self?.models.forEach { $0.unlocked() } }
        shared.notifier?.onResponse = { [weak self] account, response in self?.respond(account, response) }
    }

    private func hook(_ model: AppModel) {
        model.hub = self
        let id = model.accountID
        model.onAccountRemoved = { [weak self] in self?.finishRemoving(id) }
    }

    // MARK: Lifecycle

    /// Starts the account on screen, which opens the accounts, then the rest.
    public func start(verbose: Bool = false) {
        self.verbose = verbose
        guard !started else { return }
        started = true
        if live { shared.notifier?.requestAuthorization() }
        active.start(verbose: verbose)
        for model in models where model !== active { model.start(verbose: verbose) }
        guard live, let manager = LiveAccounts.shared.current else { return }
        let list = manager.accounts()
        for id in list.order where model(id) == nil {
            let model = makeModel(id)
            models.append(model)
            model.start(verbose: verbose)
        }
        models.sort { list.order.firstIndex(of: $0.accountID) ?? .max < list.order.firstIndex(of: $1.accountID) ?? .max }
        log.info("accounts: \(self.models.count, privacy: .public) running")
    }

    public func shutdown() {
        for model in models { model.shutdown() }
    }

    /// Whether the person is looking at the app; only the account on screen
    /// says it is online.
    public func setActive(_ isActive: Bool) {
        for model in models { model.setActive(isActive) }
    }

    private func makeModel(_ id: String) -> AppModel {
        let model = AppModel(accountID: id, paths: paths, preferences: preferences, shared: shared)
        model.setOnScreen(false)
        hook(model)
        onModelAdded(model)
        return model
    }

    public func model(_ id: String) -> AppModel? {
        models.first { $0.accountID == id }
    }

    // MARK: Switching

    /// Puts account `id` in the window. Leaving an account that was being
    /// added and never linked removes it, as upstream does.
    public func switchTo(_ id: String) {
        guard let next = model(id), next !== active else { return }
        let abandoned = adding.flatMap { adding in
            adding.new == active.accountID && !active.isLinked ? adding.new : nil
        }
        adding = nil
        show(next)
        if let abandoned { remove(abandoned) }
    }

    private func show(_ next: AppModel) {
        let previous = active
        previous.setOnScreen(false)
        active = next
        next.setOnScreen(true)
        try? LiveAccounts.shared.current?.setActive(id: next.accountID)
        onActiveChanged(next)
    }

    // MARK: Adding and removing

    /// A new account, on screen to be linked with a QR code or a phone
    /// number. Leaving it before it links removes it.
    public func addAccount() {
        guard live, let manager = LiveAccounts.shared.current else { return }
        do {
            let id = try manager.add()
            // Known as being added before anything shows it, so the window
            // goes straight to linking.
            adding = (new: id, before: active.accountID)
            let model = makeModel(id)
            models.append(model)
            model.start(verbose: verbose)
            show(model)
        } catch {
            active.report(error: String(localized: "Could not add an account: \(String(describing: error))"))
        }
    }

    /// Marks `id` as being added, for tests that have no account manager.
    func beginAdding(_ id: String, before: String) {
        adding = (new: id, before: before)
    }

    /// The account being added linked: it stays when the person leaves it.
    func linked(_ id: String) {
        if adding?.new == id { adding = nil }
    }

    /// Goes back to the account that was on screen before adding one.
    public func cancelAdding() {
        guard let adding else { return }
        switchTo(adding.before)
    }

    /// Unlinks account `id`, and once its backend has stopped deletes its
    /// files. The last account is only unlinked: the window always shows one.
    public func remove(_ id: String) {
        guard let model = model(id) else { return }
        if models.count <= 1 {
            model.unlink()
            return
        }
        model.sendSetting(.removeAccount)
    }

    private func finishRemoving(_ id: String) {
        guard let index = models.firstIndex(where: { $0.accountID == id }) else { return }
        let model = models[index]
        guard models.count > 1 else {
            // Another removal got there first: keep this one, linkable.
            model.unlink()
            return
        }
        if model === active {
            let next = models[index == 0 ? 1 : index - 1]
            adding = nil
            show(next)
        }
        model.shutdown()
        model.forgetAccount()
        models.remove(at: index)
        onModelRemoved(model)
        do {
            try LiveAccounts.shared.current?.removeFiles(id: id)
        } catch {
            active.report(error: String(describing: error))
        }
    }

    // MARK: Notifications and unread chats

    private func respond(_ account: String, _ response: Notifier.Response) {
        guard let model = model(account) else { return }
        if case .open = response, model !== active {
            switchTo(account)
        }
        model.handle(response)
    }

    /// Unread chats in every account, for the Dock.
    public var unreadEverywhere: Int {
        models.reduce(0) { $0 + $1.chats.unreadChatCount }
    }

    /// Unread chats in the accounts not on screen, for the switcher's dot.
    public var unreadElsewhere: Int {
        models.reduce(0) { $0 + ($1 === active ? 0 : $1.chats.unreadChatCount) }
    }
}
