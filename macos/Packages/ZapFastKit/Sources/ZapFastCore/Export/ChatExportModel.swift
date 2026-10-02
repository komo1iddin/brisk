import Foundation

/// What a message is in an exported chat.
nonisolated enum ChatExportBody: Sendable, Equatable {
    /// Already written as HTML: text, a place, a poll, a note.
    case html(String)
    /// An attachment: written into its folder when it is downloaded and media
    /// was asked for, and named by a placeholder otherwise. The caption is HTML.
    case media(
        kind: ChatExportMediaKind, source: URL?, name: String?,
        bytes: UInt64, seconds: UInt32?, caption: String
    )
}

nonisolated enum ChatExportMediaKind: Sendable, Equatable, Hashable {
    case photo, video, voice, audio, sticker, document

    /// The folder its files go into, beside the pages.
    var folder: String {
        switch self {
        case .photo: "photos"
        case .video: "videos"
        case .voice: "voice_messages"
        case .audio: "audio"
        case .sticker: "stickers"
        case .document: "files"
        }
    }

    /// The word its numbered file names start with.
    var word: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        case .voice: "voice"
        case .audio: "audio"
        case .sticker: "sticker"
        case .document: "file"
        }
    }
}

/// One message of an export, with the pieces that depend on the reader's
/// language already written.
nonisolated struct ChatExportEntry: Sendable, Equatable {
    struct Reply: Sendable, Equatable {
        let author: String
        let summary: String
    }

    struct Reaction: Sendable, Equatable {
        let emoji: String
        let count: Int
    }

    let id: String
    let timestamp: Int64
    /// "30 September 2026": a new day starts a new heading.
    let day: String
    /// "22:15", in the reader's clock.
    let time: String
    let author: String
    let fromMe: Bool
    let forwarded: Bool
    let edited: Bool
    let reply: Reply?
    let reactions: [Reaction]
    let body: ChatExportBody
}

nonisolated public struct ChatExportSummary: Sendable, Equatable {
    /// The folder written, with the pages and the media in it.
    public let folder: URL
    /// The first page, which is the one to open.
    public let page: URL
    public let messages: Int
    /// Attachments written into the folder.
    public let attachments: Int
    /// Attachments left out because they were never downloaded or could
    /// not be copied (only counted when media was asked for).
    public let missingMedia: Int
}
