import Foundation
import ZapFastBridge
import ZapFastCore

extension BubbleSource {
    /// A message's drawn bubble, with names from the stores, or nil for the
    /// kinds a SwiftUI row still shows (polls, places, contacts, business
    /// cards). Reads the stores, so a caller under observation hears of a
    /// name that changes.
    ///
    /// A voice message's photo shows beside it with `voiceAvatars` (else
    /// only its speed while it plays: `playingVoice` is asked then, so only
    /// then is playback observed); `own` names our own recordings.
    /// `original` finds a quoted message among those loaded, for its kind
    /// and picture.
    @MainActor
    static func make(
        _ message: MessageRecord,
        startsRun: Bool,
        isGroup: Bool,
        colors: BubbleColors,
        chats: ChatStore,
        voiceAvatars: Bool = true,
        playingVoice: () -> String? = { nil },
        own: (id: String, name: String)? = nil,
        original: (String) -> MessageRecord? = { _ in nil }
    ) -> BubbleSource? {
        var text = ""
        var emojiOnly = false
        var attachment: Attachment?
        var linkPreview: LinkPreview?
        switch message.content {
        case .text(let body, nil):
            text = body
            emojiOnly = BodyText.isOnlyEmoji(body)
        case let .text(body, preview?):
            text = body
            linkPreview = LinkPreview(url: preview.url, title: preview.title, description: preview.description, thumbnail: message.thumbnail)
        case let .document(media, fileName, caption, pages):
            text = caption ?? ""
            attachment = .document(Document(
                fileName: fileName, mime: media.mime, bytes: media.size, pages: pages, path: media.path, thumbnail: message.thumbnail
            ))
        case let .image(caption, media):
            text = caption ?? ""
            attachment = .picture(.init(message: message, media: media, kind: .photo, seconds: nil))
        case let .video(caption, media, seconds, gif, note):
            text = caption ?? ""
            attachment = .picture(.init(message: message, media: media, kind: note ? .roundVideo : gif ? .gif : .video, seconds: seconds))
        case let .sticker(media, animated):
            attachment = .picture(.init(message: message, media: media, kind: animated ? .animatedSticker : .sticker, seconds: nil))
        case .revoked:
            attachment = .placeholder(symbol: "nosign", text: String(localized: "This message was deleted"))
        case .unsupported(let what):
            attachment = .placeholder(symbol: "exclamationmark.triangle", text: what)
        case let .phoneOnly(viewOnce, liveLocation, once):
            attachment = .placeholder(
                symbol: "iphone", text: PhoneOnlyText.text(viewOnce: viewOnce, liveLocation: liveLocation, once: once)
            )
        case let .audio(media, seconds, voiceNote, waveform):
            let recorderID = message.fromMe ? own?.id ?? message.sender : message.sender
            let recorderName = message.fromMe ? own?.name ?? "" : chats.personName(message.sender, hint: message.senderName)
            attachment = .voice(Voice(
                seconds: seconds, waveform: waveform, path: media.path, mime: media.mime, voiceNote: voiceNote,
                hasSide: voiceNote && (voiceAvatars || playingVoice() == message.id),
                recorderID: recorderID, recorderName: String(recorderName.trimmingPrefix("~")),
                played: message.status == .played
            ))
        case .interactive, .location, .liveLocation, .contact, .poll, .stickerPack:
            return nil
        }
        return BubbleSource(
            id: message.id,
            fromMe: message.fromMe,
            startsRun: startsRun,
            text: text,
            emojiOnly: emojiOnly,
            mentions: message.mentions,
            mentionNames: Dictionary(
                message.mentions.map { ($0.id, chats.displayName($0.id)) },
                uniquingKeysWith: { first, _ in first }
            ),
            senderName: startsRun && !message.fromMe && isGroup
                ? chats.personName(message.sender, hint: message.senderName) : nil,
            senderID: message.sender,
            forwarded: message.forwarded,
            quote: message.quoted.map { quoted in
                let preview = QuotePreview(quoted, original: quoted.id.isEmpty ? nil : original(quoted.id))
                return .init(
                    name: chats.displayName(quoted.sender, hint: quoted.senderName), summary: preview.summary,
                    senderID: quoted.sender, symbol: preview.symbol, thumbnail: preview.thumbnail
                )
            },
            edited: message.edited,
            timestamp: message.timestamp,
            status: message.status,
            reactions: message.reactions,
            colors: colors,
            attachment: attachment,
            linkPreview: linkPreview
        )
    }
}

extension BubbleSource.Picture {
    init(message: MessageRecord, media: MediaInfo, kind: Kind, seconds: UInt32?) {
        self.init(
            kind: kind, width: media.width, height: media.height, path: media.path, mime: media.mime,
            bytes: media.size, seconds: seconds, thumbnail: message.thumbnail
        )
    }
}
