import Foundation
import ZapFastBridge

/// The rows of a conversation: messages with a separator at each new day,
/// and a flag for the first message of a run from one sender, which is the
/// one that shows the sender's name and the bubble's tail.
public enum TimelineRow: Identifiable, Hashable, Sendable {
    case day(id: String, title: String)
    case message(MessageRecord, startsRun: Bool)
    /// "3 unread messages", above the first message unread when the chat
    /// was opened.
    case unread(count: UInt32)

    public var id: String {
        switch self {
        case .day(let id, _): id
        case .message(let message, _): message.id
        case .unread: "unread"
        }
    }

    public static func build(
        _ messages: [MessageRecord],
        unread: UnreadDivider? = nil,
        calendar: Calendar = .current,
        now: Date = .now
    ) -> [TimelineRow] {
        var rows: [TimelineRow] = []
        rows.reserveCapacity(messages.count + 8)
        var previous: MessageRecord?
        for message in messages {
            let date = DateText.date(message.timestamp)
            let newDay = previous.map {
                !calendar.isDate(DateText.date($0.timestamp), inSameDayAs: date)
            } ?? true
            if newDay {
                let day = calendar.startOfDay(for: date)
                rows.append(.day(
                    id: "day-\(Int(day.timeIntervalSince1970))",
                    title: DateText.day(message.timestamp, now: now, calendar: calendar)
                ))
            }
            let dividerHere = unread?.message == message.id
            if let unread, dividerHere {
                rows.append(.unread(count: unread.count))
            }
            let startsRun = newDay || dividerHere || previous?.sender != message.sender
                || previous?.fromMe != message.fromMe
                // A long pause starts a new run even from the same sender.
                || message.timestamp - (previous?.timestamp ?? 0) > 5 * 60
            rows.append(.message(message, startsRun: startsRun))
            previous = message
        }
        return rows
    }
}
