import AppKit
import QuartzCore
import Testing
import ZapFastBridge
import ZapFastCore
@testable import FeatureConversation

@MainActor
@Suite(.serialized)
struct TimelineRowBackingTests {
    @Test func transparentRowsKeepCellsAndTheirHighlightsAcrossScrollingAndResize() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-row-backing-\(UUID())")
        let model = AppModel(backend: PreviewBackend(), paths: AppPaths(data: folder, caches: folder),
                             preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        let controller = TimelineController()
        let scroll = controller.makeScrollView()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close(); withExtendedLifetime(model) {} }
        controller.place(frame: CGRect(x: 0, y: 0, width: 760, height: 400), topInset: 20, bottomInset: 40)
        let messages = (0..<80).map { index in
            MessageRecord(id: "m\(index)", chat: "fixture", sender: "sender", senderName: nil, fromMe: index % 2 == 0,
                timestamp: Int64(index * 86_400), content: .text(text: "Synthetic row content", preview: nil),
                status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
                mentions: [], forwarded: false, thumbnail: nil, summary: "")
        }
        controller.update(chatID: "fixture", messages: messages, revision: 1, isGroup: false, model: model,
                          style: .standard, unread: nil, jump: nil, scrollRequest: nil, onReachTop: {}, onScrollState: { _ in })
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.preparing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(!controller.preparing && !controller.items.isEmpty)
        var bubbles = 0, chips = 0
        let standardRowRole = NSTableRowView().accessibilityRole()
        for width in [760.0, 900.0, 640.0] {
            controller.place(frame: CGRect(x: 0, y: 0, width: width, height: 400), topInset: 20, bottomInset: 40)
            for fraction in [0.0, 0.5, 1.0, 0.0] {
                let top = max(0, controller.tableView.frame.height - controller.clip.bounds.height) * fraction
                controller.clip.scroll(to: CGPoint(x: 0, y: top))
                scroll.reflectScrolledClipView(controller.clip)
                controller.tableView.layoutSubtreeIfNeeded()
                scroll.displayIfNeeded()
                CATransaction.flush()
                let visible = controller.tableView.rows(in: controller.clip.documentVisibleRect)
                try #require(visible.location != NSNotFound && visible.length > 0)
                for row in visible.location..<min(NSMaxRange(visible), controller.items.count) {
                    let rowView = try #require(controller.tableView.rowView(atRow: row, makeIfNecessary: true) as? TimelineRowView)
                    rowView.updateLayer()
                    #expect(!rowView.isOpaque && rowView.layer?.contents == nil && rowView.layer?.backgroundColor == nil)
                    #expect(rowView.accessibilityRole() == standardRowRole)
                    let cell = try #require(rowView.view(atColumn: 0) as? NSView)
                    // AppKit may reserve padding beside the table column;
                    // the cell follows its column rectangle, not that strip.
                    let columnRect = controller.tableView.frameOfCell(atColumn: 0, row: row)
                    #expect(abs(cell.frame.width - columnRect.width) < 0.5)
                    #expect(abs(cell.frame.height - rowView.bounds.height) < 0.5)
                    if let bubble = cell as? BubbleCell {
                        bubbles += 1
                        bubble.setHighlighted(true, animated: false)
                        #expect((bubble.layer?.backgroundColor?.alpha ?? 0) > 0)
                        bubble.setHighlighted(false, animated: false)
                    } else if cell is ChipCell { chips += 1 }
                }
                #expect(controller.tableView.selectedRowIndexes.isEmpty)
            }
        }
        #expect(bubbles > 0 && chips > 0)
    }
}
