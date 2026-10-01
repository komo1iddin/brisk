import Foundation
import ZapFastBridge

/// The rows of a conversation: messages with a separator at each new day,
/// and flags for the first message of a run from one sender, which shows
/// the sender's name, and the last, which shows their photo in a group and
/// the bubble's tail, as WhatsApp does.
public enum TimelineRow: Identifiable, Hashable, Sendable {
    case day(id: String, title: String)
    case message(MessageRecord, startsRun: Bool, endsRun: Bool)
    /// "3 unread messages", above the first message unread when the chat
    /// was opened.
    case unread(count: UInt32)

    public var id: String {
        switch self {
        case .day(let id, _): id
        case .message(let message, _, _): message.id
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
        // The previous message's row, which ends its run when this one
        // starts another.
        var previousRow: Int?
        // The current day's bounds, so the calendar is asked once per day
        // rather than once per message.
        var day: DateInterval?
        for message in messages {
            let date = DateText.date(message.timestamp)
            let newDay = day.map { !($0.start <= date && date < $0.end) } ?? true
            if newDay {
                let interval = calendar.dateInterval(of: .day, for: date)
                    ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
                day = interval
                rows.append(.day(
                    id: "day-\(Int(interval.start.timeIntervalSince1970))",
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
            if let previousRow, case let .message(before, starts, _) = rows[previousRow] {
                rows[previousRow] = .message(before, startsRun: starts, endsRun: startsRun)
            }
            previousRow = rows.count
            rows.append(.message(message, startsRun: startsRun, endsRun: true))
            previous = message
        }
        return rows
    }
}
