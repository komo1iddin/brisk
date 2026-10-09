import AppKit
import Testing
@testable import FeatureConversation

/// The quick reactions above a message's menu.
@MainActor
struct ReactionBarTests {
    @Test func eachEmojiHasASlotAndThePlusComesLast() {
        let emojis = ["👍", "❤️", "😂", "😮", "😢", "🙏"]
        let bar = ReactionBarView(emojis: emojis, mine: "❤️", accent: .systemGreen)
        let slot = ReactionBarView.slot
        let y = bar.bounds.midY
        for index in emojis.indices {
            let x = ReactionBarView.padding + (CGFloat(index) + 0.5) * slot
            #expect(bar.slot(at: NSPoint(x: x, y: y)) == index)
        }
        let plus = ReactionBarView.padding + (CGFloat(emojis.count) + 0.5) * slot
        #expect(bar.slot(at: NSPoint(x: plus, y: y)) == emojis.count)
        #expect(bar.slot(at: NSPoint(x: -4, y: y)) == nil)
        #expect(bar.slot(at: NSPoint(x: plus, y: bar.bounds.maxY + 4)) == nil)
    }

    @Test func aMessageWithAnOpenMenuIsMarked() {
        let cell = BubbleCell(identifier: BubbleCell.identifier)
        #expect(cell.layer?.backgroundColor.map { $0.alpha == 0 } ?? true)
        cell.setMenuOpen(true)
        #expect((cell.layer?.backgroundColor?.alpha ?? 0) > 0)
        cell.setMenuOpen(false)
        #expect(cell.layer?.backgroundColor.map { $0.alpha == 0 } ?? true)
    }
}
