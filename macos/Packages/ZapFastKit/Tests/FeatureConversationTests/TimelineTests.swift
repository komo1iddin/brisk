import AppKit
import Testing
import ZapFastBridge
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
struct TextBubbleLayoutTests {
    private func source(
        _ text: String,
        fromMe: Bool = false,
        emojiOnly: Bool = false,
        quote: TextBubbleSource.Quote? = nil,
        reactions: [ReactionInfo] = [],
        textScale: Double = 1
    ) -> TextBubbleSource {
        TextBubbleSource(
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
    func theSelectableTextLaysOutAsDrawn(textScale: Double) {
        for phrase in phrases {
            for limit in [240.0, 560.0] {
                let layout = TimelineLayoutEngine.layout(for: source(phrase, textScale: textScale), widthLimit: limit)
                let view = BodyTextView(layout: layout)
                let manager = view.layoutManager!
                manager.ensureLayout(for: view.textContainer!)
                let used = manager.usedRect(for: view.textContainer!)
                #expect(abs(ceil(used.height) - layout.body.rect.height) <= 1, "\(phrase) at \(limit): text view \(used.height), drawn \(layout.body.rect.height), lines \(manager.numberOfGlyphs)")
                #expect(used.width <= layout.body.rect.width + 0.5, "\(phrase) at \(limit)")
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
                #expect(layout.footer.rect.maxY <= layout.body.rect.maxY + TimelineGeometry.footerDrop + 0.5)
                #expect(layout.body.string.length == layout.bodyLength + TimelineText.reserveLength)
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
        #expect(alone.footer.rect.minY >= alone.body.rect.maxY)
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
        #expect(bigger.body.rect.height > normal.body.rect.height)
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
