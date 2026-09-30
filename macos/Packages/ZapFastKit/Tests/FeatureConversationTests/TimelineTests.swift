import AppKit
import Testing
import ZapFastBridge
import ZapFastCore
@testable import FeatureConversation

@MainActor
struct TimelineDiffTests {
    @Test func anOlderPageOfTheSameDayIsAPatchAboveTheReader() {
        // The day's separator moves up with the older page; the rows the
        // reader sees stay, so the table inserts and keeps their place.
        let old = ["day-1", "c", "d"]
        let new = ["day-1", "a", "b", "c", "d"]
        let diff = TimelineDiff.between(old, new) { _, _ in false }
        #expect(diff == .patch(removed: [], inserted: [1, 2], changed: []))
    }

    @Test func sameRowsReportOnlyWhatChanged() {
        let ids = ["day-1", "a", "b"]
        #expect(TimelineDiff.between(ids, ids) { _, _ in false } == .none)
        #expect(TimelineDiff.between(ids, ids) { old, _ in old == 2 } == .update(changed: [2]))
    }

    @Test func rowsThatStayPairUpAcrossRemovals() {
        let diff = TimelineDiff.between(["a", "b", "c"], ["a", "c", "d"]) { old, new in old == 2 && new == 1 }
        #expect(diff == .patch(removed: [1], inserted: [2], changed: [1]))
    }

    @Test func emptyOrLargeChangesReload() {
        #expect(TimelineDiff.between([], ["a"]) { _, _ in false } == .reload)
        let many = (0..<400).map(String.init)
        #expect(TimelineDiff.between(["x"], many) { _, _ in false } == .reload)
    }
}

@MainActor
struct BubbleLayoutTests {
    private func source(
        _ text: String,
        fromMe: Bool = false,
        emojiOnly: Bool = false,
        quote: BubbleSource.Quote? = nil,
        reactions: [ReactionInfo] = [],
        textScale: Double = 1
    ) -> BubbleSource {
        BubbleSource(
            id: "m", fromMe: fromMe, startsRun: true, text: text, emojiOnly: emojiOnly, mentions: [],
            mentionNames: [:], senderName: fromMe ? nil : "Aziza", senderID: "a@s.whatsapp.net",
            forwarded: false, quote: quote, edited: false, timestamp: 1_780_000_000,
            status: fromMe ? .read : .none, reactions: reactions,
            colors: BubbleColors(TimelineStyle(theme: .standard, textScale: textScale))
        )
    }

    private let phrases = [
        "Salom!",
        "Ok 👍",
        "Loyiha bo'yicha hujjatni yubordim, ko'rib chiqib fikringizni yozing. Ayniqsa ikkinchi bo'limdagi arxitektura qismiga e'tibor bering.",
        "Привет! Как дела?",
        "https://core.telegram.org/tdlib/getting-started",
        "*Bold* _italic_ ~gone~ `code` and a long enough tail to wrap onto another line or two.",
        "Bugungi reja:\n1. TDLib build\n2. Timeline prototipi\n3. Benchmark",
    ]

    /// The text view laid over a bubble for selection must place the text
    /// exactly where the layer drew it, or the text jumps under the pointer.
    @Test(arguments: [1.0, 0.8, 1.6])
    func theSelectableTextLaysOutAsDrawn(textScale: Double) throws {
        for phrase in phrases {
            for limit in [240.0, 560.0] {
                let layout = TimelineLayoutEngine.layout(for: source(phrase, textScale: textScale), widthLimit: limit)
                let body = try #require(layout.body)
                let view = BodyTextView(layout: layout, body: body)
                let manager = view.layoutManager!
                manager.ensureLayout(for: view.textContainer!)
                let used = manager.usedRect(for: view.textContainer!)
                #expect(abs(ceil(used.height) - body.rect.height) <= 1, "\(phrase) at \(limit): text view \(used.height), drawn \(body.rect.height), lines \(manager.numberOfGlyphs)")
                #expect(used.width <= body.rect.width + 0.5, "\(phrase) at \(limit)")
            }
        }
    }

    @Test func bubblesStayWithinTheirLimitAndHoldTheFooter() {
        for phrase in phrases {
            for fromMe in [false, true] {
                let layout = TimelineLayoutEngine.layout(for: source(phrase, fromMe: fromMe), widthLimit: 300)
                let bubble = CGRect(origin: .zero, size: layout.bubbleSize)
                #expect(layout.bubbleSize.width <= 300)
                #expect(bubble.contains(layout.footer.rect.insetBy(dx: 0.5, dy: 0.5)), "\(phrase)")
                #expect(layout.footer.rect.maxY <= (layout.body?.rect.maxY ?? 0) + TimelineGeometry.footerDrop + 0.5)
                #expect(layout.body?.string.length == layout.bodyLength + TimelineText.reserveLength)
            }
        }
    }

    @Test func aShortMessageIsAsWideAsItsText() {
        let short = TimelineLayoutEngine.layout(for: source("Salom!"), widthLimit: 560)
        let long = TimelineLayoutEngine.layout(for: source(phrases[2]), widthLimit: 560)
        #expect(short.bubbleSize.width < 200)
        #expect(long.bubbleSize.width == 560)
    }

    @Test func emojiAloneFloatWithTheTimeInACapsule() {
        let alone = TimelineLayoutEngine.layout(for: source("😂", fromMe: true, emojiOnly: true), widthLimit: 560)
        #expect(alone.bare)
        #expect(alone.footer.capsule != nil)
        #expect(alone.footer.rect.minY >= (alone.body?.rect.maxY ?? .infinity))
        let quoting = TimelineLayoutEngine.layout(
            for: source("😂", emojiOnly: true, quote: .init(name: "Bobur", summary: "Photo", senderID: "b")),
            widthLimit: 560
        )
        #expect(!quoting.bare)
        #expect(quoting.footer.capsule == nil)
    }

    @Test func reactionsAddTheirOverlapToTheRow() {
        let plain = TimelineLayoutEngine.layout(for: source("Salom!"), widthLimit: 560)
        let reacted = TimelineLayoutEngine.layout(
            for: source("Salom!", reactions: [
                ReactionInfo(sender: "b", fromMe: false, emoji: "👍"),
                ReactionInfo(sender: "c", fromMe: true, emoji: "👍"),
            ]),
            widthLimit: 560
        )
        #expect(reacted.pills.count == 1)
        #expect(reacted.pills[0].count != nil)
        #expect(reacted.pills[0].mine)
        #expect(reacted.rowHeight == plain.rowHeight + reacted.pillsSize.height - TimelineGeometry.reactionOverlap)
    }

    @Test func biggerTextMakesTallerBubbles() {
        let normal = TimelineLayoutEngine.layout(for: source(phrases[2]), widthLimit: 400)
        let bigger = TimelineLayoutEngine.layout(for: source(phrases[2], textScale: 1.4), widthLimit: 400)
        #expect((bigger.body?.rect.height ?? 0) > (normal.body?.rect.height ?? 0))
        #expect(source(phrases[2]) != source(phrases[2], textScale: 1.4))
    }

    /// Layouts are made on the table's background queue; anything main-actor
    /// inside them would stop the app there, not in a main-thread test.
    @Test func laysOutOffTheMainThread() async {
        let source = source(phrases[5], fromMe: true)
        let height = await withCheckedContinuation { continuation in
            DispatchQueue(label: "test.timeline-layout").async {
                continuation.resume(returning: TimelineLayoutEngine.layout(for: source, widthLimit: 320).rowHeight)
            }
        }
        #expect(height == TimelineLayoutEngine.layout(for: source, widthLimit: 320).rowHeight)
    }

    @Test func wideTimelinesShareOneLayout() {
        #expect(TimelineGeometry.bubbleWidthLimit(rowWidth: 900) == TimelineGeometry.bubbleWidthLimit(rowWidth: 1_400))
        #expect(TimelineGeometry.bubbleWidthLimit(rowWidth: 500) < TimelineGeometry.bubbleWidthLimit(rowWidth: 900))
    }

    @Test func manyMessagesLayOutInParallelAsOneByOne() {
        let sources = (0..<300).map { source(phrases[$0 % phrases.count], fromMe: $0 % 3 == 0) }
        let parallel = TimelineLayoutEngine.layouts(for: sources, widthLimit: 420)
        let serial = sources.map { TimelineLayoutEngine.layout(for: $0, widthLimit: 420) }
        #expect(parallel.map(\.rowHeight) == serial.map(\.rowHeight))
        #expect(parallel.map(\.bubbleSize.width) == serial.map(\.bubbleSize.width))
    }
}

@MainActor
struct BubbleSourceTests {
    private let chats = ChatStore(session: SessionStore())
    private let colors = BubbleColors(.standard)

    private func message(_ content: MessageContent, fromMe: Bool = false) -> MessageRecord {
        MessageRecord(
            id: "m", chat: "c@g.us", sender: "a@s.whatsapp.net", senderName: "Aziza", fromMe: fromMe,
            timestamp: 1_780_000_000, content: content, status: .none, deliveredAt: nil, readAt: nil,
            quoted: nil, reactions: [], edited: false, mentions: [], forwarded: false, thumbnail: nil, summary: ""
        )
    }

    @Test func deletedAndUnshownMessagesAreDrawnAsPlaceholders() throws {
        let deleted = try #require(BubbleSource.make(message(.revoked), startsRun: true, isGroup: true, colors: colors, chats: chats))
        #expect(deleted.attachment == .placeholder(symbol: "nosign", text: "This message was deleted"))
        #expect(deleted.text.isEmpty)
        #expect(deleted.senderName == "~Aziza")
        let phone = try #require(BubbleSource.make(
            message(.phoneOnly(viewOnce: true, liveLocation: false, once: nil)), startsRun: false, isGroup: true, colors: colors, chats: chats
        ))
        #expect(phone.senderName == nil)
        if case .placeholder(let symbol, _) = phone.attachment { #expect(symbol == "iphone") } else { Issue.record("not a placeholder") }
    }

    @Test func kindsWithoutADrawnBubbleStaySwiftUIRows() {
        let poll = message(.poll(question: "?", options: ["a"], state: PollSummary(
            selectable: 1, counts: [0], selected: [], voters: 0, canVote: true, historyComplete: true,
            refreshNeeded: false, refreshing: false, refreshFailed: false, votes: []
        )))
        #expect(BubbleSource.make(poll, startsRun: true, isGroup: false, colors: colors, chats: chats) == nil)
        let contact = message(.contact(displayName: "Dilnoza", vcard: "BEGIN:VCARD\nEND:VCARD"))
        #expect(BubbleSource.make(contact, startsRun: true, isGroup: false, colors: colors, chats: chats) == nil)
    }

    @Test func aPlaceholderHasItsTimeOnALineOfItsOwn() throws {
        let source = try #require(BubbleSource.make(message(.revoked, fromMe: true), startsRun: true, isGroup: false, colors: colors, chats: chats))
        let layout = TimelineLayoutEngine.layout(for: source, widthLimit: 400)
        let placeholder = try #require(layout.placeholder)
        #expect(layout.body == nil)
        #expect(layout.footer.rect.minY >= placeholder.text.rect.maxY)
        #expect(layout.footer.rect.maxX <= layout.bubbleSize.width - TimelineGeometry.bubblePadding.width + 0.5)
        #expect(CGRect(origin: .zero, size: layout.bubbleSize).contains(placeholder.text.rect))
        #expect(layout.accessibilityLabel.contains("This message was deleted"))
    }

    /// Colours made off the main actor still follow the appearance.
    @Test func fadedColoursFollowLightAndDark() {
        let faded = TimelineText.faded(.labelColor, 0.75)
        var light = NSColor.clear
        var dark = NSColor.clear
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { light = faded.usingColorSpace(.sRGB)! }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { dark = faded.usingColorSpace(.sRGB)! }
        #expect(light.redComponent < 0.2)
        #expect(dark.redComponent > 0.8)
        #expect(abs(light.alphaComponent - NSColor.labelColor.usingColorSpace(.sRGB)!.alphaComponent * 0.75) < 0.05)
    }
}

@MainActor
struct PictureBubbleTests {
    private let chats = ChatStore(session: SessionStore())
    private let colors = BubbleColors(.standard)

    private func source(_ content: MessageContent, fromMe: Bool = false, startsRun: Bool = true) throws -> BubbleSource {
        let message = MessageRecord(
            id: "p", chat: "c@g.us", sender: "a@s.whatsapp.net", senderName: "Aziza", fromMe: fromMe,
            timestamp: 1_780_000_000, content: content, status: fromMe ? .read : .none, deliveredAt: nil, readAt: nil,
            quoted: nil, reactions: [], edited: false, mentions: [], forwarded: false, thumbnail: Data([1, 2, 3]), summary: ""
        )
        return try #require(BubbleSource.make(message, startsRun: startsRun, isGroup: true, colors: colors, chats: chats))
    }

    private func media(width: UInt32? = 1280, height: UInt32? = 960, path: String? = nil) -> MediaInfo {
        MediaInfo(mime: "image/jpeg", size: 1_000, width: width, height: height, path: path)
    }

    @Test func eachKindOfPictureIsDrawn() throws {
        let photo = try source(.image(caption: "Salom", media: media()))
        #expect(photo.text == "Salom")
        #expect(photo.attachment?.picture?.kind == .photo)
        #expect(photo.attachment?.picture?.thumbnail == Data([1, 2, 3]))
        let note = try source(.video(caption: nil, media: media(), seconds: 12, gif: false, note: true))
        #expect(note.attachment?.picture?.kind == .roundVideo)
        #expect(note.attachment?.picture?.seconds == 12)
        let gif = try source(.video(caption: nil, media: media(), seconds: 3, gif: true, note: false))
        #expect(gif.attachment?.picture?.kind == .gif)
        let sticker = try source(.sticker(media: media(width: 512, height: 512), animated: true))
        #expect(sticker.attachment?.picture?.kind == .animatedSticker)
    }

    /// `VisualMedia.displaySize`, which the drawn picture keeps.
    @Test func picturesKeepTheirShapeWithinTheirBounds() throws {
        let landscape = try #require(try source(.image(caption: nil, media: media())).attachment?.picture)
        #expect(landscape.displaySize == CGSize(width: 300, height: 225))
        let tiny = try #require(try source(.image(caption: nil, media: media(width: 40, height: 20))).attachment?.picture)
        #expect(tiny.displaySize == CGSize(width: 120, height: 80))
        let unknown = try #require(try source(.image(caption: nil, media: media(width: nil, height: nil))).attachment?.picture)
        #expect(unknown.displaySize == CGSize(width: 300, height: 198))
        let sticker = try #require(try source(.sticker(media: media(width: 512, height: 512), animated: false)).attachment?.picture)
        #expect(sticker.displaySize == CGSize(width: 160, height: 160))
    }

    @Test func aPhotoSetsItsBubblesWidthAndItsCaptionWrapsInIt() throws {
        let caption = "Tog'dagi manzara, kechqurun. Juda chiroyli joy ekan, keyingi safar birga boramiz."
        let layout = TimelineLayoutEngine.layout(for: try source(.image(caption: caption, media: media())), widthLimit: 560)
        let picture = try #require(layout.picture)
        let body = try #require(layout.body)
        #expect(layout.bubbleSize.width == 300 + TimelineGeometry.mediaPadding * 2)
        #expect(picture.frame == CGRect(x: TimelineGeometry.mediaPadding, y: picture.frame.minY, width: 300, height: 225))
        #expect(body.rect.minY > picture.frame.maxY)
        #expect(body.rect.minX == TimelineGeometry.mediaPadding + TimelineGeometry.mediaTextInset)
        #expect(body.rect.maxX <= picture.frame.maxX - TimelineGeometry.mediaTextInset + 0.5)
        #expect(layout.footer.rect.minY >= body.rect.maxY)
        #expect(layout.accessibilityLabel.contains("Photo"))
    }

    @Test func stickersAndRoundVideosFloatWithoutABubble() throws {
        let sticker = TimelineLayoutEngine.layout(for: try source(.sticker(media: media(width: 512, height: 512), animated: false), startsRun: false), widthLimit: 560)
        #expect(sticker.bare)
        #expect(sticker.bubbleColor == nil)
        #expect(sticker.picture?.frame.origin == .zero)
        #expect(sticker.footer.capsule != nil)
        let note = TimelineLayoutEngine.layout(for: try source(.video(caption: nil, media: media(), seconds: 18, gif: false, note: true), fromMe: true), widthLimit: 560)
        #expect(note.picture?.circle == true)
        #expect(note.picture?.frame.size == CGSize(width: 220, height: 220))
        // The length is centred at the bottom of the circle.
        let duration = try #require(note.picture?.duration)
        #expect(abs(duration.capsule.midX - 110) <= 1)
    }

    @Test func aPictureWiderThanTheTimelineShrinksInShape() throws {
        let layout = TimelineLayoutEngine.layout(for: try source(.image(caption: nil, media: media())), widthLimit: 200)
        let frame = try #require(layout.picture?.frame)
        #expect(frame.width == 200 - TimelineGeometry.mediaPadding * 2)
        #expect(abs(frame.width / frame.height - 300 / 225) < 0.02)
    }
}

@MainActor
struct DocumentAndLinkBubbleTests {
    private let chats = ChatStore(session: SessionStore())
    private let colors = BubbleColors(.standard)

    private func layout(_ content: MessageContent, thumbnail: Data? = nil, width: CGFloat = 560) throws -> BubbleLayout {
        let message = MessageRecord(
            id: "d", chat: "c@s.whatsapp.net", sender: "a@s.whatsapp.net", senderName: nil, fromMe: false,
            timestamp: 1_780_000_000, content: content, status: .none, deliveredAt: nil, readAt: nil,
            quoted: nil, reactions: [], edited: false, mentions: [], forwarded: false, thumbnail: thumbnail, summary: ""
        )
        let source = try #require(BubbleSource.make(message, startsRun: true, isGroup: false, colors: colors, chats: chats))
        return TimelineLayoutEngine.layout(for: source, widthLimit: width)
    }

    private func pdf(path: String? = nil) -> MediaInfo {
        MediaInfo(mime: "application/pdf", size: 2_400_000, width: nil, height: nil, path: path)
    }

    @Test func aDocumentIsACardOfItsIconNameAndDetail() throws {
        let layout = try layout(.document(media: pdf(), fileName: "Hisobot.pdf", caption: "Ko'ring", pages: 3), thumbnail: Data([1]))
        let card = try #require(layout.document)
        #expect(card.frame.width == TimelineGeometry.documentWidth)
        #expect(card.preview?.height == TimelineGeometry.documentPreviewHeight)
        #expect(card.document.detail.contains("3 pages"))
        #expect(card.document.detail.hasSuffix("PDF"))
        // Not here yet: room for the arrow, and the name stays clear of it.
        let indicator = try #require(card.indicator)
        #expect(card.name.rect.maxX <= indicator.minX)
        #expect(card.icon.minY >= (card.preview?.maxY ?? 0))
        // The caption follows the card; the time is a line of its own.
        let body = try #require(layout.body)
        #expect(body.rect.minY > card.frame.maxY)
        #expect(layout.footer.rect.minY >= body.rect.maxY)
        #expect(layout.accessibilityLabel.contains("Hisobot.pdf"))
    }

    @Test func aDocumentHereHasNoArrowAndAPDFShowsItsPage() throws {
        let here = try layout(.document(media: pdf(path: "/tmp/a.pdf"), fileName: "a.pdf", caption: nil, pages: nil))
        #expect(here.document?.indicator == nil)
        #expect(here.document?.preview != nil)
        let zip = try layout(.document(
            media: MediaInfo(mime: "application/zip", size: 10, width: nil, height: nil, path: "/tmp/a.zip"),
            fileName: "a.zip", caption: nil, pages: nil
        ))
        #expect(zip.document?.preview == nil)
        #expect(zip.body == nil)
    }

    @Test func aLinkPreviewFollowsTheTextWithTheTimeUnderIt() throws {
        let preview = LinkPreviewInfo(url: "https://apple.com/design", title: "Design", description: "Resources for Apple platforms.")
        let layout = try layout(.text(text: "Mana: https://apple.com/design", preview: preview), thumbnail: Data([1]))
        let card = try #require(layout.linkPreview)
        let body = try #require(layout.body)
        #expect(card.frame.minY >= body.rect.maxY + TimelineGeometry.mediaTextInset - 0.5)
        #expect(card.image?.size == CGSize(width: TimelineGeometry.linkImage, height: TimelineGeometry.linkImage))
        #expect(card.host.string.string == "apple.com")
        #expect(card.frame.height >= TimelineGeometry.linkImage + TimelineGeometry.mediaTextInset * 2)
        #expect(layout.footer.rect.minY >= card.frame.maxY)
        // Its text keeps its links for the selectable view.
        #expect(layout.linkedBody?.attribute(.link, at: 7, effectiveRange: nil) != nil)
    }
}
