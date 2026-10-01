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
        VStack(spacing: 0) {
            DaySeparator(title: "Today")
            ForEach(Array(Self.messages.enumerated()), id: \.offset) { index, message in
                MessageRow(
                    message: message,
                    startsRun: index == 0 || Self.messages[index - 1].sender != message.sender,
                    endsRun: index == Self.messages.count - 1 || Self.messages[index + 1].sender != message.sender,
                    isGroup: true,
                    model: model
                )
            }
        }
        .padding(.vertical, Metrics.l)
    }

    private static let base: Int64 = 1_790_000_000

    /// A made-up map: streets on a pale ground, as a sender's preview.
    static let mapPicture: Data = {
        let image = NSImage(size: NSSize(width: 320, height: 180), flipped: false) { rect in
            NSColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 1).setFill()
            rect.fill()
            NSColor(red: 0.78, green: 0.88, blue: 0.74, alpha: 1).setFill()
            NSRect(x: 30, y: 20, width: 90, height: 60).fill()
            NSColor.white.setStroke()
            for x in stride(from: 0.0, through: 320, by: 64) {
                let path = NSBezierPath()
                path.lineWidth = 6
                path.move(to: NSPoint(x: x, y: 0))
                path.line(to: NSPoint(x: x + 40, y: 180))
                path.stroke()
            }
            return true
        }
        let rep = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        return rep?.representation(using: .jpeg, properties: [:]) ?? Data()
    }()

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
        .sample("11", from: "a", content: .video(
            caption: nil,
            media: MediaInfo(mime: "video/mp4", size: 1_200_000, width: 640, height: 360, path: "/dev/null"),
            seconds: 42, gif: false, note: false
        )),
        .sample("12", from: "a", content: .video(
            caption: nil,
            media: MediaInfo(mime: "video/mp4", size: 300_000, width: 480, height: 270, path: "/dev/null"),
            seconds: 3, gif: true, note: false
        )),
        .sample("13", fromMe: true, content: .video(
            caption: nil,
            media: MediaInfo(mime: "video/mp4", size: 500_000, width: 400, height: 400, path: "/dev/null"),
            seconds: 12, gif: false, note: true
        ), status: .read),
        .sample("14", from: "b", content: .interactive(
            text: "Buyurtmangiz tayyor",
            card: InteractiveCardInfo(
                body: "Buyurtmangiz tayyor. Qanday olasiz?",
                buttons: [
                    InteractiveButtonInfo(label: "Yetkazib bering", url: nil, action: .reply),
                    InteractiveButtonInfo(label: "Filialni tanlash", url: nil, action: .select(options: [
                        InteractiveOptionInfo(section: "Toshkent", title: "Chilonzor", description: "09:00–21:00"),
                    ])),
                    InteractiveButtonInfo(label: "Promokod", url: nil, action: .copy(code: "ZAP10")),
                    InteractiveButtonInfo(label: "Saytda ko'rish", url: "https://example.com", action: .unavailable),
                ],
                image: nil, needsPhone: false, carousel: [], thumbnail: nil
            )
        )),
        .sample("10", from: "b", content: .poll(
            question: "Tushlikka qayerga boramiz?",
            options: ["Osh markazi", "Somsaxona", "Uyda ovqatlanamiz"],
            state: PollSummary(
                selectable: 1, counts: [3, 1, 0], selected: [0], voters: 4, canVote: true,
                historyComplete: true, refreshNeeded: false, refreshing: false, refreshFailed: false, votes: []
            )
        )),
        .sample("20", from: "b", content: .contact(
            displayName: "Dilnoza",
            vcard: "BEGIN:VCARD\nVERSION:3.0\nFN:Dilnoza Karimova\nitem1.TEL;waid=998901234567:+998 90 123 45 67\nEND:VCARD"
        )),
        .sample("21", from: "a", content: .location(
            latitude: 41.3111, longitude: 69.2797, name: "Amir Temur xiyoboni", address: "Toshkent"
        ), thumbnail: mapPicture),
        .sample("22", from: "b", content: .liveLocation(
            latitude: 41.31, longitude: 69.28, accuracyM: 12, speedMps: 8.5, headingDeg: 90,
            ended: false, updated: 1_790_001_300
        ), thumbnail: mapPicture),
    ]
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
        status: DeliveryState = .none,
        thumbnail: Data? = nil
    ) -> MessageRecord {
        MessageRecord(
            id: id, chat: "gallery@g.us", sender: "\(sender)@s.whatsapp.net",
            senderName: ["a": "Aziza", "b": "Bobur"][sender], fromMe: fromMe,
            timestamp: 1_790_000_000 + (Int64(id) ?? 0) * 60,
            content: content ?? .text(text: text ?? "", preview: nil), status: status,
            deliveredAt: nil, readAt: nil, quoted: quoted, reactions: reactions, edited: edited,
            mentions: [], forwarded: forwarded, thumbnail: thumbnail, summary: text ?? "Attachment"
        )
    }
}
#endif
