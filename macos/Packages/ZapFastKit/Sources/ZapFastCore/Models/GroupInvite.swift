import Foundation
import ZapFastBridge

/// A group invite being looked at or joined (upstream's `GroupInvite`).
/// `code` is empty while the person is still pasting a link.
public struct GroupInvite: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Waiting for a link to be pasted.
        case entering
        case loading
        case ready(InviteInfo)
        case joining(InviteInfo)
        case failed(String)
    }

    public let id = UUID()
    public internal(set) var code: String
    public internal(set) var state: State
}
