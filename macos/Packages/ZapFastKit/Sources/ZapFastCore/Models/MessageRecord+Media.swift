import Foundation
import ZapFastBridge

extension MessageContent {
    /// The attachment, for content that has one.
    public var media: MediaInfo? {
        switch self {
        case .image(_, let media), .sticker(let media, _):
            media
        case .video(_, let media, _, _, _), .audio(let media, _, _, _), .document(let media, _, _, _):
            media
        case .text, .interactive, .stickerPack, .location, .liveLocation, .contact, .poll,
             .revoked, .unsupported, .phoneOnly:
            nil
        }
    }

    /// The same content with its attachment's local file replaced.
    func withMediaPath(_ path: String?) -> MessageContent {
        func moved(_ media: MediaInfo) -> MediaInfo {
            var media = media
            media.path = path
            return media
        }
        switch self {
        case let .image(caption, media):
            return .image(caption: caption, media: moved(media))
        case let .video(caption, media, seconds, gif, note):
            return .video(caption: caption, media: moved(media), seconds: seconds, gif: gif, note: note)
        case let .audio(media, seconds, voiceNote, waveform):
            return .audio(media: moved(media), seconds: seconds, voiceNote: voiceNote, waveform: waveform)
        case let .document(media, fileName, caption, pages):
            return .document(media: moved(media), fileName: fileName, caption: caption, pages: pages)
        case let .sticker(media, animated):
            return .sticker(media: moved(media), animated: animated)
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

    mutating func setMediaPath(_ path: String) {
        content = content.withMediaPath(path)
    }

    /// A fresh copy of this message that keeps the file an older copy had
    /// downloaded, unless the fresh copy carries its own.
    func keepingMediaPath(of previous: MessageRecord) -> MessageRecord {
        guard content.media != nil, content.media?.path == nil,
              let path = previous.content.media?.path else { return self }
        var message = self
        message.setMediaPath(path)
        return message
    }
}
