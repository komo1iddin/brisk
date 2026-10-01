import Foundation

/// Dates as the chat list, bubbles and day separators show them, following
/// the system's locale and 12/24-hour setting.
public nonisolated enum DateText {
    public static func date(_ unixSeconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(unixSeconds))
    }

    /// Chat row: a time today, "Yesterday", a weekday this week, else a date.
    public static func chatRow(_ unixSeconds: Int64, now: Date = .now, calendar: Calendar = .current) -> String {
        guard unixSeconds > 0 else { return "" }
        let date = date(unixSeconds)
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "Yesterday")
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// Bubble footer: the time only.
    public static func bubble(_ unixSeconds: Int64) -> String {
        date(unixSeconds).formatted(date: .omitted, time: .shortened)
    }

    /// Day separator: "Today", "Yesterday", a weekday, or a full date.
    public static func day(_ unixSeconds: Int64, now: Date = .now, calendar: Calendar = .current) -> String {
        let date = date(unixSeconds)
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear
            ? date.formatted(.dateTime.day().month(.wide))
            : date.formatted(.dateTime.day().month(.wide).year())
    }

    /// When a receipt arrived (upstream's `moment_stamp`): the time today,
    /// "Yesterday at 14:02", a weekday this week, else the date and time.
    public static func moment(_ unixSeconds: Int64, now: Date = .now, calendar: Calendar = .current) -> String {
        let date = date(unixSeconds)
        let time = date.formatted(date: .omitted, time: .shortened)
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? .max
        switch days {
        case 0:
            return time
        case 1:
            return String(localized: "Yesterday at \(time)")
        case 2...6:
            return String(localized: "\(date.formatted(.dateTime.weekday(.wide))) at \(time)")
        default:
            return String(localized: "\(date.formatted(date: .abbreviated, time: .omitted)) at \(time)")
        }
    }

    /// The presence line as the phone words it (upstream's `last_seen`):
    /// "last seen today at 14:02", "last seen yesterday at 14:02", a weekday
    /// within the week, and only the date before that.
    public static func lastSeen(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? .max
        switch days {
        // A clock slightly ahead of ours still means today.
        case ...0:
            return String(localized: "last seen today at \(time)")
        case 1:
            return String(localized: "last seen yesterday at \(time)")
        case 2...6:
            return String(localized: "last seen \(date.formatted(.dateTime.weekday(.wide))) at \(time)")
        default:
            return String(localized: "last seen \(date.formatted(date: .abbreviated, time: .omitted))")
        }
    }
}
