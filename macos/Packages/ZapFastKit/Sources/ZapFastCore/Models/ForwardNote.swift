import Foundation
import ZapFastBridge

/// A message typed in the forward sheet, held back until the messages
/// forwarded to its chat have left, so it arrives after them as on the
/// phone. The worker queues forwards one at a time but sends text at
/// once, so sending both together would put the note first.
struct ForwardNote: Identifiable, Equatable, Sendable {
    let id = UUID()
    let chat: String
    let text: String
    /// How many forwarded messages to wait for.
    let expected: Int
    /// Unix seconds when the forward went out; earlier forwards to the
    /// same chat are not ours to wait for.
    let since: Int64
    private(set) var states: [String: DeliveryState] = [:]

    init(chat: String, text: String, expected: Int, since: Int64) {
        self.chat = chat
        self.text = text
        self.expected = expected
        self.since = since
    }

    /// Follows one of our forwarded messages in this chat.
    mutating func follow(_ message: MessageRecord) {
        guard message.chat == chat, message.fromMe, message.forwarded, message.timestamp >= since else { return }
        states[message.id] = message.status
    }

    /// Every forwarded message is stored and none is still on its way.
    var isReady: Bool {
        states.count >= expected && !states.values.contains(.pending)
    }

    /// Whether any forwarded message arrived at all.
    var sawForwards: Bool {
        !states.isEmpty
    }
}
