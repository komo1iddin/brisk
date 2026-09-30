import Foundation
import ZapFastBridge

/// Messages as text, the way the phone copies and shares several of them:
/// `[09:28, 30/09/2026] Ada: message` per line (upstream's
/// `transcript::Row`). One message alone is just its text.
public enum MessageTranscript {
    /// `name` gives a message's author as the transcript shows it;
    /// `mentionName` a mentioned person's.
    public static func text(
        _ messages: [MessageRecord],
        name: (MessageRecord) -> String,
        mentionName: (String) -> String,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        if messages.count == 1, let message = messages.first {
            return line(for: message, mentionName: mentionName)
        }
        return messages.map { message in
            "[\(stamp(message.timestamp, locale: locale, timeZone: timeZone))] \(name(message)): "
                + line(for: message, mentionName: mentionName)
        }
        .joined(separator: "\n")
    }

    /// A message's marker for what is not text ("[photo]"), then its text
    /// with mentions shown by name.
    static func line(for message: MessageRecord, mentionName: (String) -> String) -> String {
        let body = WhatsAppMarkup.resolvingMentions(
            body(of: message.content) ?? "", mentions: message.mentions, name: mentionName
        )
        guard let marker = marker(for: message.content) else { return body }
        return body.isEmpty ? marker : "\(marker) \(body)"
    }

    /// "9:28, 30/09/2026" in the reader's own time and date order.
    static func stamp(_ unixSeconds: Int64, locale: Locale, timeZone: TimeZone) -> String {
        let date = DateText.date(unixSeconds)
        var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        time.timeZone = timeZone
        var day = Date.FormatStyle(locale: locale).day(.twoDigits).month(.twoDigits).year()
        day.timeZone = timeZone
        return "\(date.formatted(time)), \(date.formatted(day))"
    }

    private static func body(of content: MessageContent) -> String? {
        switch content {
        case .text(let text, _), .interactive(let text, _): text
        case .image(let caption, _), .video(let caption, _, _, _, _), .document(_, _, let caption, _),
             .stickerPack(_, _, _, let caption):
            caption
        default: nil
        }
    }

    private static func marker(for content: MessageContent) -> String? {
        switch content {
        case .image: String(localized: "[photo]")
        case .video(_, _, _, true, _): String(localized: "[GIF]")
        case .video: String(localized: "[video]")
        case .audio(_, let seconds?, true, _):
            String(localized: "[voice message, \(Duration.seconds(Int(seconds)).formatted(.time(pattern: .minuteSecond)))]")
        case .audio(_, nil, true, _): String(localized: "[voice message]")
        case .audio: String(localized: "[audio]")
        case .document(_, let fileName, _, _): String(localized: "[document: \(fileName)]")
        case .sticker: String(localized: "[sticker]")
        case .stickerPack(let name, _, _, _): String(localized: "[sticker pack: \(name)]")
        case .location: String(localized: "[location]")
        case .liveLocation(_, _, _, _, _, let ended, _):
            ended ? String(localized: "[live location ended]") : String(localized: "[live location]")
        case .contact(let name, _): String(localized: "[contact: \(name)]")
        case .poll(let question, _, _): String(localized: "[poll: \(question)]")
        case .text, .interactive, .revoked, .unsupported, .phoneOnly: nil
        }
    }
}
