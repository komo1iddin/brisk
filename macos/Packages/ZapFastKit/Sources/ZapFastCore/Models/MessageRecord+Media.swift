import Foundation
import ZapFastBridge

extension MessageContent {
    /// The attachment, for content that has one; an interactive message's
    /// is its card's image (upstream's `Content::media`).
    public var media: MediaInfo? {
        switch self {
        case .image(_, let media), .sticker(let media, _):
            media
        case .video(_, let media, _, _, _), .audio(let media, _, _, _), .document(let media, _, _, _):
            media
        case .interactive(_, let card):
            card?.image
        case .text, .stickerPack, .location, .liveLocation, .contact, .poll,
             .revoked, .unsupported, .phoneOnly:
            nil
        }
    }

    /// A carousel card's image (upstream's `media_at`), or the main one.
    public func media(card: Int?) -> MediaInfo? {
        guard let card else { return media }
        guard case .interactive(_, let info?) = self, info.carousel.indices.contains(card) else { return nil }
        return info.carousel[card].image
    }

    /// The same content with an attachment's local file replaced: the main
    /// one, or a carousel card's.
    func withMediaPath(_ path: String?, card: Int? = nil) -> MessageContent {
        func moved(_ media: MediaInfo) -> MediaInfo {
            var media = media
            media.path = path
            return media
        }
        switch self {
        case let .image(caption, media):
            return card == nil ? .image(caption: caption, media: moved(media)) : self
        case let .video(caption, media, seconds, gif, note):
            return card == nil ? .video(caption: caption, media: moved(media), seconds: seconds, gif: gif, note: note) : self
        case let .audio(media, seconds, voiceNote, waveform):
            return card == nil ? .audio(media: moved(media), seconds: seconds, voiceNote: voiceNote, waveform: waveform) : self
        case let .document(media, fileName, caption, pages):
            return card == nil ? .document(media: moved(media), fileName: fileName, caption: caption, pages: pages) : self
        case let .sticker(media, animated):
            return card == nil ? .sticker(media: moved(media), animated: animated) : self
        case .interactive(let text, var info?):
            if let card {
                guard info.carousel.indices.contains(card), let image = info.carousel[card].image else { return self }
                info.carousel[card].image = moved(image)
            } else {
                guard let image = info.image else { return self }
                info.image = moved(image)
            }
            return .interactive(text: text, card: info)
        case .text, .interactive, .stickerPack, .location, .liveLocation, .contact, .poll,
             .revoked, .unsupported, .phoneOnly:
            return self
        }
    }
}

extension MessageRecord {
    public var mediaURL: URL? {
        content.media?.path.map { URL(filePath: $0) }
    }

    mutating func setMediaPath(_ path: String, card: Int? = nil) {
        content = content.withMediaPath(path, card: card)
    }

    /// A fresh copy of this message that keeps the files an older copy had
    /// downloaded, unless the fresh copy carries its own: the main one and
    /// each carousel card's (upstream's `keep_local_paths`).
    func keepingMediaPath(of previous: MessageRecord) -> MessageRecord {
        var message = self
        if content.media != nil, content.media?.path == nil, let path = previous.content.media?.path {
            message.setMediaPath(path)
        }
        if case .interactive(_, let card?) = content {
            for index in card.carousel.indices where card.carousel[index].image?.path == nil {
                if let path = previous.content.media(card: index)?.path {
                    message.setMediaPath(path, card: index)
                }
            }
        }
        return message
    }
}
