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
        // Whether the message at `index` starts a run: the first of a day,
        // under the divider, from someone else than the one before, or
        // after a long pause even from the same sender.
        func startsRun(at index: Int, newDay: Bool) -> Bool {
            guard index > 0, !newDay else { return true }
            return unread?.message == messages[index].id
                || messages[index - 1].sender != messages[index].sender
                || messages[index - 1].fromMe != messages[index].fromMe
                || messages[index].timestamp - messages[index - 1].timestamp > 5 * 60
        }
        // The current day's bounds, so the calendar is asked once per day
        // rather than once per message.
        var day: DateInterval?
        for (index, message) in messages.enumerated() {
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
            // A run ends where the next message starts one.
            var endsRun = true
            if index + 1 < messages.count, let day {
                let next = DateText.date(messages[index + 1].timestamp)
                endsRun = startsRun(at: index + 1, newDay: !(day.start <= next && next < day.end))
            }
            rows.append(.message(message, startsRun: startsRun(at: index, newDay: newDay), endsRun: endsRun))
        }
        return rows
    }
}
