import Foundation
import ZapFastBridge

/// A chat written out the way WhatsApp's own "Export Chat" does: a text file
/// with a line per message, `[date, time] Name: message`, and, when asked
/// for, the downloaded attachments beside it in a zip.
///
/// Reading the archive and writing files happen off the main actor; the
/// names and the words come from here, on it, so they are the ones the
/// interface shows.
public enum ChatExport {
    /// How many messages one read of the archive returns.
    static let pageSize: UInt32 = 500

    /// Reads a whole chat, newest page first, and returns its messages as
    /// entries, oldest first. `progress` is told how many have been read.
    /// Only the archive is read: nothing is asked of the phone, so a chat
    /// holds what this Mac has, which may start later than the chat does.
    static func collect(
        chat: String,
        reader: any ChatReaderProtocol,
        me: String,
        name: (MessageRecord) -> String,
        mentionName: (String) -> String,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        pageSize: UInt32 = ChatExport.pageSize,
        progress: (Int) -> Void = { _ in }
    ) async throws -> [ChatExportEntry] {
        var pages: [[ChatExportEntry]] = []
        var read = 0
        var before: PageKey?
        while true {
            try Task.checkCancellation()
            let page = try await readPage(reader, chat: chat, before: before, limit: pageSize)
            guard let oldest = page.first else { break }
            pages.append(page.map {
                entry(for: $0, me: me, name: name, mentionName: mentionName, locale: locale, timeZone: timeZone)
            })
            read += page.count
            progress(read)
            // A short page is the start of the chat.
            if page.count < Int(pageSize) { break }
            before = PageKey(timestamp: oldest.timestamp, id: oldest.id)
        }
        return pages.reversed().flatMap { $0 }
    }

    @concurrent
    private static func readPage(
        _ reader: any ChatReaderProtocol, chat: String, before: PageKey?, limit: UInt32
    ) async throws -> [MessageRecord] {
        try reader.page(chat: chat, before: before, limit: limit)
    }

    /// What the Save panel proposes: the phone's own name for an export,
    /// "WhatsApp Chat - Name", as a zip when media goes along.
    public static func suggestedFileName(chat title: String, withMedia: Bool) -> String {
        let name = ChatExportWriter.FileNames.documentName(String(title.prefix(80))) ?? String(localized: "Chat")
        return String(localized: "WhatsApp Chat - \(name)") + (withMedia ? ".zip" : ".txt")
    }

    // MARK: One message

    static func entry(
        for message: MessageRecord,
        me: String,
        name: (MessageRecord) -> String,
        mentionName: (String) -> String,
        locale: Locale,
        timeZone: TimeZone
    ) -> ChatExportEntry {
        ChatExportEntry(
            timestamp: message.timestamp,
            stamp: stamp(message.timestamp, locale: locale, timeZone: timeZone),
            author: message.fromMe ? me : name(message),
            body: body(of: message, mentionName: mentionName)
        )
    }

    /// "30/09/2026, 09:28:15" in the reader's own date order and clock, as
    /// the phone writes it.
    static func stamp(_ unixSeconds: Int64, locale: Locale, timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .numeric, time: .standard, locale: locale)
        style.timeZone = timeZone
        return DateText.date(unixSeconds).formatted(style)
    }

    static func body(of message: MessageRecord, mentionName: (String) -> String) -> ChatExportBody {
        func written(_ text: String?) -> String {
            WhatsAppMarkup.resolvingMentions(text ?? "", mentions: message.mentions, name: mentionName)
        }
        func file(_ media: MediaInfo) -> URL? {
            media.path.map { URL(filePath: $0) }
        }
        switch message.content {
        case .text(let text, _):
            let edited = message.edited ? " " + String(localized: "<This message was edited>") : ""
            return .text(written(text) + edited)
        case .interactive(let text, _):
            return .text(written(text))
        case .image(let caption, let media):
            return .media(kind: .photo, source: file(media), name: nil, caption: written(caption))
        case .video(let caption, let media, _, _, _):
            return .media(kind: .video, source: file(media), name: nil, caption: written(caption))
        case .audio(let media, _, _, _):
            return .media(kind: .audio, source: file(media), name: nil, caption: "")
        case .document(let media, let fileName, let caption, _):
            return .media(kind: .document, source: file(media), name: fileName, caption: written(caption))
        case .sticker(let media, _):
            return .media(kind: .sticker, source: file(media), name: nil, caption: "")
        case .stickerPack(let name, _, _, let caption):
            let heading = String(localized: "sticker pack: \(name)")
            let note = written(caption)
            return .text(note.isEmpty ? heading : heading + "\n" + note)
        case .location(let latitude, let longitude, let place, let address):
            var text = String(localized: "location: \(mapLink(latitude, longitude))")
            for detail in [place, address] {
                if let detail, !detail.isEmpty { text += "\n" + detail }
            }
            return .text(text)
        case .liveLocation(let latitude, let longitude, _, _, _, let ended, _):
            let text = String(localized: "live location: \(mapLink(latitude, longitude))")
            return .text(ended ? text + " " + String(localized: "(ended)") : text)
        case .contact(let displayName, _):
            return .text(String(localized: "contact: \(displayName)"))
        case .poll(let question, let options, let state):
            return .text(poll(question, options: options, counts: state.counts))
        case .revoked:
            return .text(message.fromMe
                ? String(localized: "You deleted this message")
                : String(localized: "This message was deleted"))
        case .unsupported:
            return .text(String(localized: "<This message type is not supported>"))
        case .phoneOnly(let viewOnce, _, _):
            return .text(viewOnce
                ? String(localized: "<View once message>")
                : String(localized: "<This message is only available on your phone>"))
        }
    }

    /// An Apple Maps link, which opens in Maps on a Mac and in the browser
    /// elsewhere. Written with a `.` decimal mark whatever the locale.
    static func mapLink(_ latitude: Double, _ longitude: Double) -> String {
        "https://maps.apple.com/?ll=" + String(format: "%.6f,%.6f", latitude, longitude)
    }

    /// The question and each answer, with its votes once there are any.
    static func poll(_ question: String, options: [String], counts: [UInt32]) -> String {
        let counted = counts.contains { $0 > 0 }
        let answers = options.enumerated().map { index, option -> String in
            let label = String(localized: "OPTION: \(option)")
            guard counted, counts.indices.contains(index) else { return label }
            let votes = counts[index]
            return votes == 1
                ? label + " " + String(localized: "(1 vote)")
                : label + " " + String(localized: "(\(votes) votes)")
        }
        return ([String(localized: "POLL:"), question] + answers).joined(separator: "\n")
    }
}
