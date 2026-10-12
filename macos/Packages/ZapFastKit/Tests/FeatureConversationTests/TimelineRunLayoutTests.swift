import AppKit
import Testing
import ZapFastBridge
@testable import FeatureConversation
@testable import ZapFastCore

@MainActor
struct TimelineRunLayoutTests {
    @Test(arguments: [true, false])
    func continuingRunReusesMeasuredTextAndPreservesGeometry(isGroup: Bool) throws {
        let message = MessageRecord(id: "fixture", chat: "synthetic", sender: "sender", senderName: nil,
            fromMe: false, timestamp: 1, content: .text(text: "Synthetic wrapped message with https://example.com", preview: nil),
            status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: nil, summary: "")
        let controller = TimelineController()
        let colors = BubbleColors(.standard)
        let source = try #require(BubbleSource.make(message, startsRun: true, endsRun: true,
                                                   isGroup: isGroup, colors: colors, chats: ChatStore(session: SessionStore())))
        func layout(_ source: BubbleSource, limit: CGFloat = 300) throws -> BubbleLayout {
            let row = TimelineRow.message(message, startsRun: true, endsRun: source.endsRun)
            guard case let .bubble(_, value) = controller.item(for: .bubble(row, source), limit: limit) else {
                Issue.record("Expected a drawn bubble")
                throw CancellationError()
            }
            return value
        }
        let original = try layout(source)
        var continuing = source
        continuing.endsRun = false
        continuing.avatarName = nil
        let reused = try layout(continuing)
        #expect(reused.body?.string === original.body?.string)
        #expect(reused.linkedBody === original.linkedBody)
        #expect(reused.bubbleSize == original.bubbleSize)
        #expect(reused.rowHeight == original.rowHeight)
        #expect(!reused.tail && reused.avatar == nil)
        let ended = try layout(source)
        #expect(ended.body?.string === original.body?.string)
        #expect(ended.tail && (ended.avatar != nil) == isGroup)

        // Real content changes and narrower reflow still measure afresh.
        var edited = source
        edited.text = "Different synthetic text"
        let changed = try layout(edited)
        #expect(changed.body?.string !== original.body?.string)
        #expect(changed.body?.string.string.contains("Different synthetic text") == true)
        let narrow = try layout(edited, limit: 180)
        #expect(narrow.widthLimit == 180)
        #expect(narrow.body?.string !== changed.body?.string)
    }
}
