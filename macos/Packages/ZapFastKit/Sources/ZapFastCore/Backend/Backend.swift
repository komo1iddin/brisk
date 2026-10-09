import Foundation
import ZapFastBridge

/// The seam between app state and the Rust backend. `LiveBackend` is the
/// real one; previews and tests pass their own.
public protocol Backend: AnyObject {
    /// Opens the archive and connects. `deliver` runs on the main actor, in
    /// the order the backend produced the events.
    func start(
        paths: AppPaths,
        verbose: Bool,
        deliver: @escaping @MainActor ([BridgeEvent]) -> Void
    ) throws
    func send(_ command: BridgeCommand)
    /// Reconnects to WhatsApp now, without waiting out the delay the library
    /// puts between tries. `false` when there is nothing to reconnect yet.
    @discardableResult
    func reconnectNow() -> Bool
    /// Opens a reader on the archive, for exporting a chat. Unlocking the
    /// archive takes a moment, so it does not run on the main actor.
    func openChatReader() async throws -> any ChatReaderProtocol
    /// Flushes and closes everything; blocks briefly.
    func shutdown()
}

extension Backend {
    @discardableResult
    public func reconnectNow() -> Bool { false }

    /// Backends without an archive have nothing to export.
    public func openChatReader() async throws -> any ChatReaderProtocol {
        throw BridgeError.NotRunning
    }
}

/// The bridge's account manager, opened once per process: it holds the data
/// folder's lock, moves a single-account setup into account 1, and keeps
/// the roster of accounts.
@MainActor
public final class LiveAccounts {
    public static let shared = LiveAccounts()
    private var opened: Result<AccountManager, any Error>?

    /// The manager, opening it on first use. A failure is kept and thrown
    /// again until `retry` forgets it.
    public func manager(paths: AppPaths, verbose: Bool) throws -> AccountManager {
        if case let .success(manager) = opened { return manager }
        do {
            let manager = try AccountManager.open(config: BridgeConfig(
                dataDir: paths.data.path(percentEncoded: false),
                cacheDir: paths.caches.path(percentEncoded: false),
                verbose: verbose
            ))
            opened = .success(manager)
            return manager
        } catch {
            opened = nil
            throw error
        }
    }

    /// The manager if it is open.
    public var current: AccountManager? {
        if case let .success(manager) = opened { manager } else { nil }
    }

    /// The account the roster puts on screen, read without opening anything.
    public static func activeAccount(paths: AppPaths) -> String {
        peekActiveAccount(config: BridgeConfig(
            dataDir: paths.data.path(percentEncoded: false),
            cacheDir: paths.caches.path(percentEncoded: false),
            verbose: false
        ))
    }
}

public final class LiveBackend: Backend {
    /// The account this backend runs.
    public let account: String
    private var client: BridgeClient?
    /// Where the account keeps downloads by default, known once started.
    public private(set) var mediaFolder: URL?

    public init(account: String) {
        self.account = account
    }

    public func start(
        paths: AppPaths,
        verbose: Bool,
        deliver: @escaping @MainActor ([BridgeEvent]) -> Void
    ) throws {
        let manager = try LiveAccounts.shared.manager(paths: paths, verbose: verbose)
        let client = try manager.client(id: account)
        try client.start(listener: EventRelay(deliver: deliver))
        self.client = client
        mediaFolder = (try? manager.mediaFolder(id: account)).map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    public func send(_ command: BridgeCommand) {
        client?.send(command: command)
    }

    @discardableResult
    public func reconnectNow() -> Bool {
        client?.reconnectNow() ?? false
    }

    public func openChatReader() async throws -> any ChatReaderProtocol {
        guard let client else { throw BridgeError.NotRunning }
        return try await Self.openReader(on: client)
    }

    @concurrent
    private static func openReader(on client: BridgeClient) async throws -> any ChatReaderProtocol {
        try client.openChatReader()
    }

    public func shutdown() {
        client?.shutdown()
    }
}

/// Receives events on the bridge's pump thread and replays them on the main
/// queue. A serial queue, not a `Task` per batch, keeps them in order.
nonisolated private final class EventRelay: EventListener, Sendable {
    private let deliver: @MainActor ([BridgeEvent]) -> Void

    init(deliver: @escaping @MainActor ([BridgeEvent]) -> Void) {
        self.deliver = deliver
    }

    func onEvents(events: [BridgeEvent]) {
        let deliver = self.deliver
        DispatchQueue.main.async {
            MainActor.assumeIsolated { deliver(events) }
        }
    }
}

/// A backend that goes nowhere, for previews, galleries, and tests.
public final class PreviewBackend: Backend {
    public private(set) var sent: [BridgeCommand] = []
    /// How many times a reconnect without waiting was asked for.
    public private(set) var reconnectsWithoutWaiting = 0

    public init() {}

    public func start(
        paths: AppPaths,
        verbose: Bool,
        deliver: @escaping @MainActor ([BridgeEvent]) -> Void
    ) throws {}

    public func send(_ command: BridgeCommand) {
        sent.append(command)
    }

    @discardableResult
    public func reconnectNow() -> Bool {
        reconnectsWithoutWaiting += 1
        return true
    }

    public func shutdown() {}
}
