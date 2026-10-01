import Foundation
import ZapFastBridge
import ZapFastCore

/// What a quote shows of the message it answers, as WhatsApp does when that
/// message is loaded: the kind's symbol, a line about it (a file's name and
/// pages, a photo's caption) and its picture on the right. Upstream's
/// summary alone when it is not.
nonisolated struct QuotePreview: Equatable, Sendable {
    var summary: String
    var symbol: String?
    /// The quoted message's JPEG preview.
    var thumbnail: Data?

    init(summary: String, symbol: String? = nil, thumbnail: Data? = nil) {
        self.summary = summary
        self.symbol = symbol
        self.thumbnail = thumbnail
    }

    init(_ quoted: QuotedMessage, original: MessageRecord?) {
        guard let original else {
            self.init(summary: quoted.summary)
            return
        }
        let thumbnail = original.thumbnail
        func caption(_ text: String?, or label: String) -> String {
            text.flatMap { $0.isEmpty ? nil : $0.split(separator: "\n", maxSplits: 1).first.map(String.init) } ?? label
        }
        switch original.content {
        case let .document(_, fileName, _, pages):
            let summary = pages.map {
                "\(fileName) • \(String(AttributedString(localized: "^[\($0) page](inflect: true)").characters))"
            } ?? fileName
            self.init(summary: summary, symbol: "doc.fill", thumbnail: thumbnail)
        case let .image(text, _):
            self.init(summary: caption(text, or: String(localized: "Photo")), symbol: "camera.fill", thumbnail: thumbnail)
        case let .video(text, _, _, gif, note):
            let label = gif ? String(localized: "GIF") : note ? String(localized: "Video message") : String(localized: "Video")
            self.init(summary: caption(text, or: label), symbol: "video.fill", thumbnail: thumbnail)
        case let .audio(_, seconds, voiceNote, _):
            let label = voiceNote ? String(localized: "Voice message") : String(localized: "Audio")
            let length = seconds.map { " (\(Duration.seconds(Int($0)).formatted(.time(pattern: .minuteSecond))))" } ?? ""
            self.init(summary: label + length, symbol: voiceNote ? "mic.fill" : "headphones")
        case .sticker:
            self.init(summary: String(localized: "Sticker"), symbol: "face.smiling")
        case let .location(_, _, name, _):
            self.init(summary: name ?? String(localized: "Location"), symbol: "mappin.and.ellipse", thumbnail: thumbnail)
        case .liveLocation:
            self.init(summary: String(localized: "Live location"), symbol: "location.fill", thumbnail: thumbnail)
        case let .contact(displayName, _):
            self.init(summary: displayName, symbol: "person.crop.circle")
        case let .poll(question, _, _):
            self.init(summary: question, symbol: "chart.bar.xaxis")
        case .text(_, .some) where thumbnail != nil:
            // A link's picture, beside its text.
            self.init(summary: quoted.summary, thumbnail: thumbnail)
        default:
            self.init(summary: quoted.summary)
        }
    }
}
