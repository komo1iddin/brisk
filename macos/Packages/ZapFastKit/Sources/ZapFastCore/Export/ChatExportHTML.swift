import Foundation

/// An export's pages: the conversation as a web page, in sequence, with
/// the day it happened under a heading, our messages on the right and theirs
/// on the left, and the media beside each message. One file, no scripts and
/// no links to anywhere but the folder's own media.
nonisolated enum ChatExportHTML {
    /// A message and the file its attachment was written to (a path inside
    /// the export folder), if it was written.
    struct Placed: Sendable {
        let entry: ChatExportEntry
        let file: String?
    }

    struct Page: Sendable {
        let title: String
        /// Whether the author is named: in a group, not in a conversation of two.
        let showsAuthors: Bool
        /// 1-based, of `pages`.
        let number: Int
        let pages: Int
        let messages: Int
        let exported: String
        let language: String
        let items: [Placed]
    }

    /// The file name of a page: `messages.html`, `messages2.html`, ...
    static func fileName(page number: Int) -> String {
        number == 1 ? "messages.html" : "messages\(number).html"
    }

    static func render(_ page: Page) -> String {
        var html = """
        <!DOCTYPE html>
        <html lang="\(escape(page.language))">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(page.title))</title>
        <style>\(style)</style>
        </head>
        <body>
        <header>
        <h1 dir="auto">\(escape(page.title))</h1>
        <p>\(escape(String(localized: "\(page.messages) messages, exported \(page.exported)")))</p>
        </header>

        """
        html += navigation(page)
        html += "<main>\n"
        var previous: Placed?
        for placed in page.items {
            let entry = placed.entry
            if previous?.entry.day != entry.day {
                html += "<div class=\"day\"><span>\(escape(entry.day))</span></div>\n"
                previous = nil
            }
            let continues = previous.map {
                $0.entry.author == entry.author && $0.entry.fromMe == entry.fromMe
                    && entry.timestamp - $0.entry.timestamp < 5 * 60
            } ?? false
            html += message(placed, showsAuthor: page.showsAuthors && !entry.fromMe && !continues, continues: continues)
            previous = placed
        }
        html += "</main>\n"
        html += navigation(page)
        html += "</body>\n</html>\n"
        return html
    }

    // MARK: A message

    private static func message(_ placed: Placed, showsAuthor: Bool, continues: Bool) -> String {
        let entry = placed.entry
        var classes = entry.fromMe ? "msg out" : "msg in"
        if continues { classes += " cont" }
        var html = "<div class=\"\(classes)\" id=\"m\(escape(anchor(entry.id)))\"><div class=\"bubble\">\n"
        if showsAuthor {
            html += "<div class=\"who\" style=\"--h:\(hue(of: entry.author))\" dir=\"auto\">\(escape(entry.author))</div>\n"
        }
        if entry.forwarded {
            html += "<div class=\"fwd\">\(escape(String(localized: "Forwarded")))</div>\n"
        }
        if let reply = entry.reply {
            html += "<blockquote dir=\"auto\"><b>\(escape(reply.author))</b>\(escape(reply.summary))</blockquote>\n"
        }
        html += body(entry.body, file: placed.file)
        var meta = escape(entry.time)
        if entry.edited { meta = escape(String(localized: "edited")) + " " + meta }
        html += "<div class=\"meta\">\(meta)</div>\n"
        if !entry.reactions.isEmpty {
            html += "<div class=\"reactions\">"
            for reaction in entry.reactions {
                html += "<span>\(escape(reaction.emoji))\(reaction.count > 1 ? " \(reaction.count)" : "")</span>"
            }
            html += "</div>\n"
        }
        html += "</div></div>\n"
        return html
    }

    private static func body(_ body: ChatExportBody, file: String?) -> String {
        switch body {
        case .html(let html):
            return "<div class=\"text\" dir=\"auto\">\(html)</div>\n"
        case let .media(kind, _, name, bytes, seconds, caption):
            var html = media(kind: kind, file: file, name: name, bytes: bytes, seconds: seconds)
            if !caption.isEmpty { html += "<div class=\"text\" dir=\"auto\">\(caption)</div>\n" }
            return html
        }
    }

    private static func media(
        kind: ChatExportMediaKind, file: String?, name: String?, bytes: UInt64, seconds: UInt32?
    ) -> String {
        guard let file else {
            return "<div class=\"omitted\">\(escape(omitted(kind, name: name)))</div>\n"
        }
        let href = escape(path(file))
        let length = seconds.map { " <small>\(escape(duration($0)))</small>" } ?? ""
        switch kind {
        case .photo:
            return "<a class=\"media\" href=\"\(href)\"><img src=\"\(href)\" loading=\"lazy\" alt=\"\"></a>\n"
        case .sticker:
            return "<img class=\"sticker\" src=\"\(href)\" loading=\"lazy\" alt=\"\">\n"
        case .video:
            return "<video class=\"media\" controls preload=\"metadata\" src=\"\(href)\"></video>\(length)\n"
        case .voice, .audio:
            return "<div class=\"voice\"><audio controls preload=\"none\" src=\"\(href)\"></audio>\(length)</div>\n"
        case .document:
            let size = bytes > 0 ? "<small>\(escape(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))</small>" : ""
            let title = escape(name ?? (file as NSString).lastPathComponent)
            return "<a class=\"doc\" href=\"\(href)\"><b dir=\"auto\">\(title)</b>\(size)</a>\n"
        }
    }

    /// What stands in for an attachment that is not in the folder.
    private static func omitted(_ kind: ChatExportMediaKind, name: String?) -> String {
        switch kind {
        case .photo: String(localized: "Photo, not included")
        case .video: String(localized: "Video, not included")
        case .voice: String(localized: "Voice message, not included")
        case .audio: String(localized: "Audio, not included")
        case .sticker: String(localized: "Sticker, not included")
        case .document: String(localized: "Document, not included") + (name.map { ": \($0)" } ?? "")
        }
    }

    private static func duration(_ seconds: UInt32) -> String {
        Duration.seconds(Int(seconds)).formatted(.time(pattern: .minuteSecond))
    }

    // MARK: Pages

    private static func navigation(_ page: Page) -> String {
        guard page.pages > 1 else { return "" }
        var html = "<nav>"
        if page.number > 1 {
            html += "<a href=\"\(fileName(page: page.number - 1))\">\(escape(String(localized: "Earlier")))</a>"
        }
        html += "<span>\(escape(String(localized: "Page \(page.number) of \(page.pages)")))</span>"
        if page.number < page.pages {
            html += "<a href=\"\(fileName(page: page.number + 1))\">\(escape(String(localized: "Later")))</a>"
        }
        return html + "</nav>\n"
    }

    // MARK: Text

    /// A message's text as HTML: the markup's styles, links to the web, and
    /// each line break kept.
    static func html(from text: AttributedString) -> String {
        var html = ""
        for run in text.runs {
            var piece = escape(String(text[run.range].characters)).replacingOccurrences(of: "\n", with: "<br>\n")
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { piece = "<code>\(piece)</code>" }
            if intent.contains(.stronglyEmphasized) { piece = "<strong>\(piece)</strong>" }
            if intent.contains(.emphasized) { piece = "<em>\(piece)</em>" }
            if intent.contains(.strikethrough) { piece = "<s>\(piece)</s>" }
            if let link = run.link, let href = safeLink(link) {
                piece = "<a href=\"\(escape(href))\">\(piece)</a>"
            }
            html += piece
        }
        return html
    }

    /// A link that goes to the web, a mail address or a phone: never a
    /// script or a file.
    static func safeLink(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme) else { return nil }
        return url.absoluteString
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    /// A path inside the folder as a link: each part percent-encoded.
    static func path(_ file: String) -> String {
        file.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
    }

    private static func anchor(_ id: String) -> String {
        String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(64).map(Character.init))
    }

    /// A hue from the name, the same every time, so each person keeps a colour.
    static func hue(of name: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Int(hash % 360)
    }

    // MARK: Style

    static let style = """
    :root{color-scheme:light dark;--bg:#efeae2;--in:#fff;--out:#d9fdd3;--text:#111b21;--sub:#667781;--chip:rgba(17,27,33,.07);--link:#027eb5}
    @media(prefers-color-scheme:dark){:root{--bg:#0b141a;--in:#202c33;--out:#005c4b;--text:#e9edef;--sub:#8696a0;--chip:rgba(233,237,239,.1);--link:#53bdeb}}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--text);font:15px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
    header,main,nav{max-width:760px;margin:0 auto;padding:0 12px}
    header{padding-top:24px}h1{margin:0;font-size:22px}header p{margin:4px 0 0;color:var(--sub);font-size:13px}
    nav{display:flex;gap:16px;justify-content:center;align-items:center;padding:14px 12px;font-size:14px;color:var(--sub)}
    a{color:var(--link)}
    .day{text-align:center;margin:18px 0 8px}.day span{background:var(--in);color:var(--sub);font-size:12.5px;padding:3px 10px;border-radius:8px;box-shadow:0 1px 1px rgba(0,0,0,.08)}
    .msg{display:flex;margin:8px 0 0}.msg.cont{margin-top:2px}.msg.out{justify-content:flex-end}
    .bubble{max-width:min(78%,560px);padding:6px 9px 4px;border-radius:9px;background:var(--in);box-shadow:0 1px 1px rgba(0,0,0,.1);overflow-wrap:anywhere}
    .out .bubble{background:var(--out)}
    .who{font-weight:600;font-size:13.5px;color:hsl(var(--h) 55% 38%)}
    @media(prefers-color-scheme:dark){.who{color:hsl(var(--h) 60% 68%)}}
    .fwd{color:var(--sub);font-style:italic;font-size:13px}
    blockquote{margin:2px 0 4px;padding:3px 8px;border-left:3px solid var(--link);background:var(--chip);border-radius:4px;font-size:13.5px;color:var(--sub)}
    blockquote b{display:block;color:var(--text);font-size:13px}
    .text{white-space:normal}.text code{font:13px ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--chip);padding:0 3px;border-radius:3px}
    .text ul{margin:4px 0 0;padding-left:18px}.text li{margin:1px 0}
    .media{display:block;max-width:100%}.media img,video.media{display:block;max-width:100%;max-height:420px;border-radius:6px}
    img.sticker{display:block;width:150px;max-width:100%}
    .voice{display:flex;align-items:center;gap:8px}.voice audio{height:34px;max-width:100%}
    .doc{display:block;padding:8px 10px;margin:2px 0;background:var(--chip);border-radius:6px;text-decoration:none;color:var(--text)}.doc small{display:block;color:var(--sub)}
    .omitted{color:var(--sub);font-style:italic;font-size:13.5px}
    .meta{text-align:right;color:var(--sub);font-size:11.5px;margin-top:1px}
    .reactions{margin-top:2px}.reactions span{display:inline-block;background:var(--chip);border-radius:10px;padding:0 6px;margin-right:3px;font-size:13px}
    small{color:var(--sub)}
    """
}
