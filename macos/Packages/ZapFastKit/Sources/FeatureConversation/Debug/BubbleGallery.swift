#if DEBUG
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Every kind of bubble with made-up content, for checking the design
/// without a linked account (see the shell's debug snapshot).
public struct BubbleGallery: View {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        let group = ChatSummary.sample(kind: .group)
        VStack(spacing: 0) {
            DaySeparator(title: "Today")
            ForEach(Array(Self.messages.enumerated()), id: \.offset) { index, message in
                MessageRow(
                    message: message,
                    startsRun: index == 0 || Self.messages[index - 1].sender != message.sender,
                    chat: group,
                    model: model
                )
            }
        }
        .padding(.vertical, Metrics.l)
    }

    private static let base: Int64 = 1_790_000_000

    static let messages: [MessageRecord] = [
        .sample("1", from: "a", text: "Salom! Qalaysiz?"),
        .sample("2", from: "a", text: "Ertaga *soat 10* da uchrashamizmi? Manzil: https://maps.apple.com"),
        .sample("3", fromMe: true, text: "Ha, albatta 👍"),
        .sample("4", fromMe: true, text: "Uzunroq xabar: bu yerda matn bir necha qatorga o'tishi kerak, pufakcha esa maksimal kenglikdan oshmasligi va vaqt oxirgi qatorga joylashishi kerak.", status: .read),
        .sample("5", from: "b", text: "😂"),
        .sample("6", from: "b", content: .document(
            media: MediaInfo(mime: "application/pdf", size: 486_400, width: nil, height: nil, path: nil),
            fileName: "Invoice.pdf", caption: nil, pages: 1
        ), forwarded: true),
        .sample("7", fromMe: true, text: "Qabul qildim", quoted: QuotedMessage(
            id: "6", sender: "b@s.whatsapp.net", senderName: "Bobur", summary: "Invoice.pdf", mentions: []
        ), edited: true, status: .delivered),
        .sample("8", from: "a", content: .audio(
            media: MediaInfo(mime: "audio/ogg; codecs=opus", size: 9_000, width: nil, height: nil, path: nil),
            seconds: 6, voiceNote: true, waveform: Data((0..<64).map { UInt8(20 + ($0 * 37) % 80) })
        ), reactions: [ReactionInfo(sender: "b@s.whatsapp.net", fromMe: false, emoji: "👍")]),
        .sample("9", fromMe: true, content: .image(
            caption: "Namuna",
            media: MediaInfo(mime: "image/jpeg", size: 65_000, width: 900, height: 1200, path: nil)
        ), status: .sent),
    ]
}

private extension ChatSummary {
    static func sample(kind: ChatKind) -> ChatSummary {
        ChatSummary(
            id: "gallery@g.us", name: "Gallery", groupSubjectKnown: true, kind: kind, lastActivity: 0,
            unread: 0, markedUnread: false, archived: false, pinned: false, pinnedAt: 0, mutedUntil: nil,
            last: nil, favorite: false, favoritePosition: 0, participants: [], readOnly: false, left: false,
            infoLocked: nil, admin: false, locked: false, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: false, looksUnread: false, phone: nil
        )
    }
}

private extension MessageRecord {
    static func sample(
        _ id: String,
        from sender: String = "me",
        fromMe: Bool = false,
        text: String? = nil,
        content: MessageContent? = nil,
        quoted: QuotedMessage? = nil,
        reactions: [ReactionInfo] = [],
        forwarded: Bool = false,
        edited: Bool = false,
        status: DeliveryState = .none
    ) -> MessageRecord {
        MessageRecord(
            id: id, chat: "gallery@g.us", sender: "\(sender)@s.whatsapp.net",
            senderName: ["a": "Aziza", "b": "Bobur"][sender], fromMe: fromMe,
            timestamp: 1_790_000_000 + (Int64(id) ?? 0) * 60,
            content: content ?? .text(text: text ?? "", preview: nil), status: status,
            deliveredAt: nil, readAt: nil, quoted: quoted, reactions: reactions, edited: edited,
            mentions: [], forwarded: forwarded, thumbnail: nil, summary: text ?? "Attachment"
        )
    }
}
#endif
