import Foundation
import ZapFastBridge

/// The rows of a conversation: messages, and the calls among them, with a
/// separator at each new day,
/// and flags for the first message of a run from one sender, which shows
/// the sender's name, and the last, which shows their photo in a group and
/// the bubble's tail, as WhatsApp does.
public enum TimelineRow: Identifiable, Hashable, Sendable {
    case day(id: String, title: String)
    case message(MessageRecord, startsRun: Bool, endsRun: Bool)
    /// "3 unread messages", above the first message unread when the chat
    /// was opened.
    case unread(count: UInt32)
    /// A call with this chat, between the messages of its time.
    case call(CallLogEntry)

    public var id: String {
        switch self {
        case .day(let id, _): id
        case .message(let message, _, _): message.id
        case .unread: "unread"
        case .call(let entry): "call-\(entry.callId)"
        }
    }

    /// `calls` are the chat's, oldest first. Those older than the first
    /// message wait for the page that reaches them, unless `fromStart`
    /// says the messages go back to the chat's beginning.
    public static func build(
        _ messages: [MessageRecord],
        calls: [CallLogEntry] = [],
        fromStart: Bool = false,
        unread: UnreadDivider? = nil,
        calendar: Calendar = .current,
        now: Date = .now
    ) -> [TimelineRow] {
        let first = messages.first?.timestamp ?? .min
        let shown = calls.filter { fromStart || $0.timestamp >= first }
        guard shown.isEmpty else {
            return interleaved(messages, calls: shown, unread: unread, calendar: calendar, now: now)
        }
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

    /// `build` for a chat with calls in view: messages and calls by time, a
    /// call ending the run before it and starting a new one after. Kept apart
    /// so the common case, no calls, pays nothing for them.
    private static func interleaved(
        _ messages: [MessageRecord],
        calls: [CallLogEntry],
        unread: UnreadDivider?,
        calendar: Calendar,
        now: Date
    ) -> [TimelineRow] {
        enum Item {
            case message(MessageRecord)
            case call(CallLogEntry)

            var timestamp: Int64 {
                switch self {
                case .message(let message): message.timestamp
                case .call(let entry): entry.timestamp
                }
            }
        }
        // Both lists are in order; a call goes after the messages of its second.
        var items: [Item] = []
        items.reserveCapacity(messages.count + calls.count)
        var nextCall = calls.startIndex
        for message in messages {
            while nextCall < calls.endIndex, calls[nextCall].timestamp < message.timestamp {
                items.append(.call(calls[nextCall]))
                nextCall += 1
            }
            items.append(.message(message))
        }
        items += calls[nextCall...].map(Item.call)

        func sameDay(_ a: Int64, _ b: Int64) -> Bool {
            calendar.isDate(DateText.date(a), inSameDayAs: DateText.date(b))
        }
        // As `build`: from someone else, after a pause, under the divider,
        // or after anything that is not a message.
        func startsRun(at index: Int) -> Bool {
            guard index > 0, case .message(let message) = items[index],
                  case .message(let previous) = items[index - 1],
                  sameDay(previous.timestamp, message.timestamp) else { return true }
            return unread?.message == message.id
                || previous.sender != message.sender
                || previous.fromMe != message.fromMe
                || message.timestamp - previous.timestamp > 5 * 60
        }

        var rows: [TimelineRow] = []
        rows.reserveCapacity(items.count + 8)
        for (index, item) in items.enumerated() {
            if index == 0 || !sameDay(items[index - 1].timestamp, item.timestamp) {
                let start = calendar.startOfDay(for: DateText.date(item.timestamp))
                rows.append(.day(
                    id: "day-\(Int(start.timeIntervalSince1970))",
                    title: DateText.day(item.timestamp, now: now, calendar: calendar)
                ))
            }
            switch item {
            case .call(let entry):
                rows.append(.call(entry))
            case .message(let message):
                if let unread, unread.message == message.id {
                    rows.append(.unread(count: unread.count))
                }
                let endsRun = index + 1 == items.count || startsRun(at: index + 1)
                rows.append(.message(message, startsRun: startsRun(at: index), endsRun: endsRun))
            }
        }
        return rows
    }
}
