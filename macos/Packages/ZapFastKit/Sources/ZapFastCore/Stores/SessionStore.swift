import Foundation
import Observation
import ZapFastBridge

/// The linked account and the state of its connection.
@Observable
public final class SessionStore {
    public struct Account: Equatable, Sendable {
        public var id: String
        /// Our privacy id (`@lid`), when known.
        public var lid: String?
        public var name: String?
        public var about: String?

        /// Every id a message of ours may carry.
        public var ids: [String] { [id] + (lid.map { [$0] } ?? []) }
    }

    public internal(set) var link: LinkState = .starting
    public internal(set) var account: Account?
    /// Link-time history sync.
    public internal(set) var isSyncing = false
    public internal(set) var syncProgress: UInt32?
    /// Account privacy turned direct-chat read receipts off.
    public internal(set) var receiptsDisabled = false
    public internal(set) var pinLimit: UInt32 = 3

    public init() {}

    /// The link itself says this device is linked, even while offline.
    public var linkSaysLinked: Bool {
        switch link {
        case .connected, .connecting, .disconnected: true
        case .starting, .unlinked, .loggedOut, .failed: false
        }
    }

    public var isLoggedOut: Bool {
        if case .loggedOut = link { true } else { false }
    }

    public var isConnected: Bool {
        if case .connected = link { true } else { false }
    }

    public func isOurs(_ id: String) -> Bool {
        account?.ids.contains(id) ?? false
    }
}
