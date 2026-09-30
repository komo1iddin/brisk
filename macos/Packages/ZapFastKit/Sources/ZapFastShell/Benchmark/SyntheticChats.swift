import Foundation
import ZapFastBridge

/// Made-up chats and messages for the timeline benchmark: the same phrases,
/// mix and seed as Telefast's benchmark, so the two can be compared.
nonisolated enum SyntheticChats {
    /// The chat opened first and paged from the archive, 60 at a time.
    static let pagedChat = "benchmark-paged@g.us"
    /// The chat whose whole history arrives in one page.
    static let fullChat = "benchmark-full@g.us"
    /// One page of history, opened after the others to time a warm open.
    static let smallChat = "benchmark-small@g.us"
    /// A chat that is not open, for events elsewhere.
    static let otherChat = "benchmark-other@s.whatsapp.net"
    static let ownID = "998900000000@s.whatsapp.net"

    private static let phrases = [
        "Salom!",
        "Qalesan? Ishlar yaxshimi?",
        "Ok 👍",
        "Ertaga soat 10 da uchrashamizmi?",
        "Did you see the new build? Scrolling feels a lot smoother now.",
        "Men hozir yo'ldaman, 15 daqiqada yetib boraman.",
        "Haha 😂😂",
        "Let me check and get back to you.",
        "Loyiha bo'yicha hujjatni yubordim, ko'rib chiqib fikringizni yozing. Ayniqsa ikkinchi bo'limdagi arxitektura qismiga e'tibor bering.",
        "Привет! Как дела?",
        "https://core.telegram.org/tdlib/getting-started",
        "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.",
        "Rahmat! 🙏",
        """
        Bugungi reja:
        1. TDLib build
        2. Timeline prototipi
        3. Benchmark
        """,
        "Liquid Glass faqat navigatsiya qatlamida bo'lishi kerak, kontentda emas, HIG shunday deydi.",
        "👀",
        "Tomorrow works for me. Let's do 3pm, and I'll bring the design review notes along with the updated mockups for the settings screens.",
    ]

    private static let names = ["Aziz", "Dilnoza", "Jasur", "Madina", "Otabek"]

    /// A group conversation, oldest first: a third of it ours, the rest
    /// from five members who arrive with their push names. With `media`,
    /// about half of it is what real chats hold besides text: photos (most
    /// downloaded), documents, voice messages, videos, stickers and link
    /// previews, and some text quotes or carries reactions.
    static func messages(chat: String, count: Int, seed: UInt64 = 42, media: SyntheticMedia? = nil) -> [MessageRecord] {
        var generator = SplitMix64(seed: seed)
        let start: Int64 = 1_780_000_000
        var made: [MessageRecord] = []
        made.reserveCapacity(count)
        for index in 0..<count {
            var text = phrases[Int(generator.next() % UInt64(phrases.count))]
            if generator.next() % 7 == 0 {
                text += " " + phrases[Int(generator.next() % UInt64(phrases.count))]
            }
            let fromMe = generator.next() % 3 == 0
            let member = Int(generator.next() % UInt64(names.count))
            var record = message(
                chat: chat,
                id: "\(chat)-\(index)",
                sender: fromMe ? ownID : "99890000000\(member)@s.whatsapp.net",
                senderName: fromMe ? nil : names[member],
                fromMe: fromMe,
                timestamp: start + Int64(index) * 97,
                text: text
            )
            if let media {
                dress(&record, text: text, previous: made.last, media: media, generator: &generator)
            }
            made.append(record)
        }
        return made
    }

    /// Gives a text message another kind of content, by the mix above.
    private static func dress(
        _ record: inout MessageRecord,
        text: String,
        previous: MessageRecord?,
        media: SyntheticMedia,
        generator: inout SplitMix64
    ) {
        let roll = generator.next() % 100
        let downloaded = generator.next() % 10
        let caption = generator.next() % 4 == 0 ? text : nil
        switch roll {
        case 0..<18:
            let photo = media.photos[Int(generator.next() % UInt64(media.photos.count))]
            record.content = .image(caption: caption, media: MediaInfo(
                mime: "image/jpeg", size: photo.bytes, width: photo.width, height: photo.height,
                path: downloaded < 7 ? photo.path : nil
            ))
            record.thumbnail = photo.thumbnail
            record.summary = caption ?? "Photo"
        case 18..<25:
            let names = ["Hisobot 2026.pdf", "Loyiha rejasi.pdf", "Shartnoma.docx", "Design review notes.pdf", "Build logs.zip"]
            let name = names[Int(generator.next() % UInt64(names.count))]
            let pdf = name.hasSuffix(".pdf")
            record.content = .document(
                media: MediaInfo(
                    mime: pdf ? "application/pdf" : "application/octet-stream", size: 180_000 + generator.next() % 4_000_000,
                    width: nil, height: nil, path: pdf && downloaded < 5 ? media.document.path : nil
                ),
                fileName: name, caption: nil, pages: pdf ? UInt32(1 + generator.next() % 12) : nil
            )
            record.thumbnail = pdf ? media.document.thumbnail : nil
            record.summary = name
        case 25..<34:
            let waveform = Data((0..<64).map { _ in UInt8(5 + generator.next() % 95) })
            record.content = .audio(
                media: MediaInfo(mime: "audio/ogg; codecs=opus", size: 24_000, width: nil, height: nil, path: downloaded < 6 ? media.voicePath : nil),
                seconds: UInt32(3 + generator.next() % 90), voiceNote: true, waveform: waveform
            )
            record.summary = "Voice message"
        case 34..<38:
            let photo = media.photos[Int(generator.next() % UInt64(media.photos.count))]
            record.content = .video(
                caption: caption,
                media: MediaInfo(mime: "video/mp4", size: 4_000_000, width: photo.width, height: photo.height, path: downloaded < 5 ? media.videoPath : nil),
                seconds: UInt32(5 + generator.next() % 120), gif: false, note: false
            )
            record.thumbnail = photo.thumbnail
            record.summary = caption ?? "Video"
        case 38..<42:
            record.content = .sticker(media: MediaInfo(
                mime: "image/webp", size: media.sticker.bytes, width: media.sticker.width, height: media.sticker.height,
                path: media.sticker.path
            ), animated: false)
            record.summary = "Sticker"
        case 42..<46:
            record.content = .text(text: text + " https://developer.apple.com/design/", preview: LinkPreviewInfo(
                url: "https://developer.apple.com/design/", title: "Design - Apple Developer",
                description: "Get the resources to design great apps for all Apple platforms."
            ))
            record.thumbnail = media.photos[0].thumbnail
        case 46..<52:
            if let previous {
                record.quoted = QuotedMessage(
                    id: previous.id, sender: previous.sender, senderName: previous.senderName,
                    summary: previous.summary, mentions: []
                )
            }
        case 52..<56:
            let emoji = ["👍", "❤️", "😂", "🙏"][Int(generator.next() % 4)]
            record.reactions = [ReactionInfo(sender: "998900000001@s.whatsapp.net", fromMe: false, emoji: emoji)]
        default:
            break
        }
    }

    static func message(
        chat: String,
        id: String,
        sender: String,
        senderName: String?,
        fromMe: Bool,
        timestamp: Int64,
        text: String
    ) -> MessageRecord {
        MessageRecord(
            id: id, chat: chat, sender: sender, senderName: senderName, fromMe: fromMe,
            timestamp: timestamp, content: .text(text: text, preview: nil),
            status: fromMe ? .read : .none, deliveredAt: nil, readAt: nil, quoted: nil,
            reactions: [], edited: false, mentions: [], forwarded: false, thumbnail: nil,
            summary: text
        )
    }

    /// The two benchmark groups, the other chat, and enough direct chats to
    /// fill a sidebar the way a real account does.
    static func chats(count: Int, newest: Int64) -> [ChatSummary] {
        var list = [
            chat(id: pagedChat, name: "Benchmark (paged)", kind: .group, activity: newest),
            chat(id: fullChat, name: "Benchmark (full)", kind: .group, activity: newest - 1),
            chat(id: otherChat, name: "Other chat", kind: .direct, activity: newest - 2),
            chat(id: smallChat, name: "Benchmark (small)", kind: .group, activity: newest - 3),
        ]
        for index in 0..<max(0, count - list.count) {
            list.append(chat(
                id: "99891\(String(format: "%07d", index))@s.whatsapp.net",
                name: "\(names[index % names.count]) \(index)",
                kind: .direct,
                activity: newest - 60 * Int64(index + 3)
            ))
        }
        return list
    }

    static func chat(id: String, name: String, kind: ChatKind, activity: Int64, unread: UInt32 = 0) -> ChatSummary {
        let text = phrases[id.utf8.reduce(0) { $0 &+ Int($1) } % phrases.count]
        return ChatSummary(
            id: id, name: name, groupSubjectKnown: true, kind: kind, lastActivity: activity,
            unread: unread, markedUnread: false, archived: false, pinned: false, pinnedAt: 0, mutedUntil: nil,
            last: ChatPreview(fromMe: false, sender: id, senderName: nil, summary: text, full: text, status: .none),
            favorite: false, favoritePosition: 0, participants: [], readOnly: false, left: false,
            infoLocked: false, admin: false, locked: false, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: false, looksUnread: unread > 0, phone: nil
        )
    }
}

/// Small seedable generator so every run produces the same conversation.
nonisolated struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
