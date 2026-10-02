import Foundation
import ZapFastBridge
@testable import ZapFastCore

/// Made-up messages for tests that need a few of one kind.
enum Records {
    static let chat = "c@s.whatsapp.net"

    static func media(_ path: String? = nil, mime: String = "image/jpeg", size: UInt64 = 1000) -> MediaInfo {
        MediaInfo(mime: mime, size: size, width: nil, height: nil, path: path)
    }

    static func message(
        _ id: String, at time: Int64 = 1_790_000_000, chat: String = Records.chat, fromMe: Bool = false,
        content: MessageContent = .text(text: "hi", preview: nil)
    ) -> MessageRecord {
        MessageRecord(
            id: id, chat: chat, sender: "a@s.whatsapp.net", senderName: nil, fromMe: fromMe,
            timestamp: time, content: content, status: .none,
            deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: nil, summary: ""
        )
    }

    static func document(_ id: String, at time: Int64 = 1_790_000_000, path: String? = nil, size: UInt64 = 1000) -> MessageRecord {
        message(id, at: time, content: .document(
            media: media(path, mime: "application/pdf", size: size), fileName: "\(id).pdf", caption: nil, pages: nil
        ))
    }

    static func voice(_ id: String, at time: Int64 = 1_790_000_000, path: String? = nil, size: UInt64 = 1000) -> MessageRecord {
        message(id, at: time, content: .audio(
            media: media(path, mime: "audio/ogg; codecs=opus", size: size), seconds: 5, voiceNote: true, waveform: Data()
        ))
    }
}
