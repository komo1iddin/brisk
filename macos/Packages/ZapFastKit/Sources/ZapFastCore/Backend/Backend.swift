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
    /// Flushes and closes everything; blocks briefly.
    func shutdown()
}

public final class LiveBackend: Backend {
    private let client = BridgeClient()

    public init() {}

    public func start(
        paths: AppPaths,
        verbose: Bool,
        deliver: @escaping @MainActor ([BridgeEvent]) -> Void
    ) throws {
        let config = BridgeConfig(
            dataDir: paths.data.path(percentEncoded: false),
            cacheDir: paths.caches.path(percentEncoded: false),
            verbose: verbose
        )
        try client.start(config: config, listener: EventRelay(deliver: deliver))
    }

    public func send(_ command: BridgeCommand) {
        client.send(command: command)
    }

    public func shutdown() {
        client.shutdown()
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

    public init() {}

    public func start(
        paths: AppPaths,
        verbose: Bool,
        deliver: @escaping @MainActor ([BridgeEvent]) -> Void
    ) throws {}

    public func send(_ command: BridgeCommand) {
        sent.append(command)
    }

    public func shutdown() {}
}
