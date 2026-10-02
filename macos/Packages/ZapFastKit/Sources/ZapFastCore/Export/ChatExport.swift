import Foundation
import ZapFastBridge

/// A chat written out as a conversation to read: a folder with its pages
/// (`messages.html`, a thousand messages each) and, when asked for, the
/// downloaded attachments in folders by kind (`photos`, `videos`,
/// `voice_messages`, `audio`, `stickers`, `files`).
///
/// Reading the archive and writing files happen off the main actor; the
/// names and the words come from here, on it, so they are the ones the
/// interface shows.
public enum ChatExport {
    /// How many messages one read of the archive returns.
    static let readSize: UInt32 = 500

    /// Reads a whole chat, newest page first, and returns its messages as
    /// entries, oldest first. `progress` is told how many have been read.
    /// Only the archive is read: nothing is asked of the phone, so a chat
    /// holds what this Mac has, which may start later than the chat does.
    static func collect(
        chat: String,
        reader: any ChatReaderProtocol,
        me: String,
        name: (MessageRecord) -> String,
        quotedName: (QuotedMessage) -> String,
        mentionName: (String) -> String,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        pageSize: UInt32 = ChatExport.readSize,
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
                entry(
                    for: $0, me: me, name: name, quotedName: quotedName, mentionName: mentionName,
                    locale: locale, timeZone: timeZone
                )
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

    /// What the export folder is called: the phone's own name for an
    /// export, "WhatsApp Chat - Name", safe as a folder name.
    public nonisolated static func suggestedFolderName(chat title: String) -> String {
        let name = ChatExportWriter.FileNames.documentName(String(title.prefix(80))) ?? String(localized: "Chat")
        return String(localized: "WhatsApp Chat - \(name)")
    }

    // MARK: One message

    static func entry(
        for message: MessageRecord,
        me: String,
        name: (MessageRecord) -> String,
        quotedName: (QuotedMessage) -> String,
        mentionName: (String) -> String,
        locale: Locale,
        timeZone: TimeZone
    ) -> ChatExportEntry {
        let date = DateText.date(message.timestamp)
        var day = Date.FormatStyle(date: .long, time: .omitted, locale: locale)
        day.timeZone = timeZone
        var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        time.timeZone = timeZone
        return ChatExportEntry(
            id: message.id,
            timestamp: message.timestamp,
            day: date.formatted(day),
            time: date.formatted(time),
            author: message.fromMe ? me : name(message),
            fromMe: message.fromMe,
            forwarded: message.forwarded,
            edited: message.edited,
            reply: message.quoted.map { .init(author: quotedName($0), summary: $0.summary) },
            reactions: reactions(of: message),
            body: body(of: message, mentionName: mentionName)
        )
    }

    /// Each emoji once, with how many people reacted with it, in the order
    /// they first appeared.
    static func reactions(of message: MessageRecord) -> [ChatExportEntry.Reaction] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for reaction in message.reactions where !reaction.emoji.isEmpty {
            if counts[reaction.emoji] == nil { order.append(reaction.emoji) }
            counts[reaction.emoji, default: 0] += 1
        }
        return order.map { .init(emoji: $0, count: counts[$0] ?? 0) }
    }

    static func body(of message: MessageRecord, mentionName: (String) -> String) -> ChatExportBody {
        /// Text as HTML: the markup's styles, links, mentions by name.
        func written(_ text: String?) -> String {
            guard let text, !text.isEmpty else { return "" }
            return ChatExportHTML.html(from: WhatsAppMarkup.attributed(text, mentions: message.mentions, name: mentionName))
        }
        func file(_ media: MediaInfo) -> URL? {
            media.path.map { URL(filePath: $0) }
        }
        func say(_ text: String) -> String { "<em>\(ChatExportHTML.escape(text))</em>" }
        switch message.content {
        case .text(let text, _):
            return .html(written(text))
        case .interactive(let text, _):
            return .html(written(text))
        case .image(let caption, let media):
            return .media(kind: .photo, source: file(media), name: nil, bytes: media.size, seconds: nil, caption: written(caption))
        case .video(let caption, let media, let seconds, _, _):
            return .media(kind: .video, source: file(media), name: nil, bytes: media.size, seconds: seconds, caption: written(caption))
        case .audio(let media, let seconds, let voiceNote, let waveform):
            return .media(
                kind: voiceNote ? .voice : .audio, source: file(media), name: nil,
                bytes: media.size, seconds: seconds, caption: "", waveform: [UInt8](waveform)
            )
        case .document(let media, let fileName, let caption, _):
            return .media(kind: .document, source: file(media), name: fileName, bytes: media.size, seconds: nil, caption: written(caption))
        case .sticker(let media, _) where WasArchive.isLottie(mime: media.mime):
            // An animation in a zip: a browser cannot play it, so it is a file.
            return .media(
                kind: .document, source: file(media), name: String(localized: "Animated sticker") + ".was",
                bytes: media.size, seconds: nil, caption: ""
            )
        case .sticker(let media, _):
            return .media(kind: .sticker, source: file(media), name: nil, bytes: media.size, seconds: nil, caption: "")
        case .stickerPack(let name, _, _, let caption):
            let heading = "<b>\(ChatExportHTML.escape(String(localized: "Sticker pack: \(name)")))</b>"
            let note = written(caption)
            return .html(note.isEmpty ? heading : heading + "<br>\n" + note)
        case .location(let latitude, let longitude, let name, let address):
            var html = placeLink(latitude, longitude, title: String(localized: "Location"))
            for detail in [name, address] {
                if let detail, !detail.isEmpty { html += "<br>\n" + ChatExportHTML.escape(detail) }
            }
            return .html(html)
        case .liveLocation(let latitude, let longitude, _, _, _, let ended, _):
            let title = ended ? String(localized: "Live location (ended)") : String(localized: "Live location")
            return .html(placeLink(latitude, longitude, title: title))
        case .contact(let displayName, _):
            return .html("<b>\(ChatExportHTML.escape(String(localized: "Contact: \(displayName)")))</b>")
        case .poll(let question, let options, let state):
            return .html(poll(question, options: options, counts: state.counts))
        case .revoked:
            return .html(say(message.fromMe
                ? String(localized: "You deleted this message")
                : String(localized: "This message was deleted")))
        case .unsupported:
            return .html(say(String(localized: "This message type is not supported")))
        case .phoneOnly(let viewOnce, _, _):
            return .html(say(viewOnce
                ? String(localized: "View once message")
                : String(localized: "This message is only available on your phone")))
        }
    }

    /// A link to the place in Apple Maps, which opens in Maps on a Mac and in
    /// the browser elsewhere. Written with a `.` decimal mark whatever the locale.
    static func placeLink(_ latitude: Double, _ longitude: Double, title: String) -> String {
        let link = "https://maps.apple.com/?ll=" + String(format: "%.6f,%.6f", latitude, longitude)
        return "<a href=\"\(ChatExportHTML.escape(link))\">\(ChatExportHTML.escape(title))</a>"
    }

    /// The question and each answer, with its votes once there are any.
    static func poll(_ question: String, options: [String], counts: [UInt32]) -> String {
        let counted = counts.contains { $0 > 0 }
        var html = "<b>\(ChatExportHTML.escape(question))</b>\n<ul>\n"
        for (index, option) in options.enumerated() {
            var line = ChatExportHTML.escape(option)
            if counted, counts.indices.contains(index) {
                let votes = counts[index]
                line += " <small>" + ChatExportHTML.escape(
                    votes == 1 ? String(localized: "1 vote") : String(localized: "\(votes) votes")
                ) + "</small>"
            }
            html += "<li>\(line)</li>\n"
        }
        return html + "</ul>"
    }
}
