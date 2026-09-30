import Foundation
import ZapFastBridge
import ZapFastCore

extension BubbleSource {
    /// A message's drawn bubble, with names from the stores, or nil for the
    /// kinds a SwiftUI row still shows (polls, places, contacts, business
    /// cards). Reads the stores, so a caller under observation hears of a
    /// name that changes.
    @MainActor
    static func make(
        _ message: MessageRecord,
        startsRun: Bool,
        isGroup: Bool,
        colors: BubbleColors,
        chats: ChatStore
    ) -> BubbleSource? {
        var text = ""
        var emojiOnly = false
        var attachment: Attachment?
        switch message.content {
        case .text(let body, nil):
            text = body
            emojiOnly = BodyText.isOnlyEmoji(body)
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
        case let .phoneOnly(viewOnce, liveLocation, _):
            attachment = .placeholder(symbol: "iphone", text: viewOnce
                ? String(localized: "View once message. Open it on your phone.")
                : liveLocation
                    ? String(localized: "Live location. See it on your phone.")
                    : String(localized: "This message is only on your phone."))
        case .text, .interactive, .audio, .document, .location, .liveLocation, .contact, .poll, .stickerPack:
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
            quote: message.quoted.map {
                .init(name: chats.displayName($0.sender, hint: $0.senderName), summary: $0.summary, senderID: $0.sender)
            },
            edited: message.edited,
            timestamp: message.timestamp,
            status: message.status,
            reactions: message.reactions,
            colors: colors,
            attachment: attachment
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
