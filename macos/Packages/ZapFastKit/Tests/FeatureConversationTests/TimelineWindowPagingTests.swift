import AppKit
import Testing
import ZapFastBridge
@testable import ZapFastCore
@testable import FeatureConversation

@MainActor
@Suite(.serialized)
struct TimelineWindowPagingTests {
    private func rows(_ range: Range<Int>) -> [MessageRecord] {
        range.map { index in
            MessageRecord(id: "m\(index)", chat: "fixture", sender: "sender", senderName: nil, fromMe: false,
                          timestamp: 1_780_000_000 + Int64(index), content: .text(text: "Synthetic window row \(index)", preview: nil),
                          status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
                          mentions: [], forwarded: false, thumbnail: nil, summary: "")
        }
    }
    private func wait(_ controller: TimelineController) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.preparing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(!controller.preparing)
    }

    @Test func aBudgetShiftKeepsTheVisibleMessageAndReleasesOldLayouts() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-window-table-\(UUID())")
        let model = AppModel(backend: PreviewBackend(), paths: AppPaths(data: folder, caches: folder))
        let store = ConversationStore()
        store.protect(["fixture"])
        store.applyMessages(chat: "fixture", messages: rows(1_200..<2_400), older: false, complete: false)
        let controller = TimelineController()
        _ = controller.makeScrollView()
        controller.place(frame: CGRect(x: 0, y: 0, width: 760, height: 400), topInset: 20, bottomInset: 40)
        func update() {
            let state = store.conversation("fixture")
            controller.hasNewer = state.hasNewer
            controller.update(chatID: "fixture", messages: state.messages, revision: state.messagesRevision,
                              changes: state.changes, isGroup: false, model: model, style: .standard,
                              unread: nil, jump: nil, scrollRequest: nil, onReachTop: {}, onScrollState: { _ in })
        }
        update()
        try await wait(controller)
        controller.clip.scroll(to: CGPoint(x: 0, y: 300))
        controller.followsBottom = false
        let anchor = try #require(controller.readingAnchor())
        store.retentionAnchor = anchor.id
        store.applyWindow(chat: "fixture", messages: rows(1_140..<1_200), query: .before(message: "m1200"),
                          hasOlder: true, hasNewer: true)
        update()
        try await wait(controller)
        let after = try #require(controller.readingAnchor())
        #expect(after.id == anchor.id && abs(after.offset - anchor.offset) < 0.5)
        #expect(controller.messages.count <= HistoryBudget.standard.rows)
        let retained = Set(controller.messages.map(\.id))
        #expect(Set(controller.bubbleLayouts.keys).isSubset(of: retained))
        #expect(controller.bubbleLayouts.count <= HistoryBudget.standard.rows)
        #expect(controller.hasNewer)
        #expect(!controller.isAtBottom)
        var requestedNewest = 0
        controller.onWantNewest = { requestedNewest += 1 }
        controller.perform(.bottom)
        #expect(requestedNewest == 1)
    }

    @Test func newerPrefetchIsOfferedAtTheWindowEdge() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-window-edge-\(UUID())")
        let model = AppModel(backend: PreviewBackend(), paths: AppPaths(data: folder, caches: folder))
        let controller = TimelineController()
        _ = controller.makeScrollView()
        controller.place(frame: CGRect(x: 0, y: 0, width: 760, height: 400), topInset: 20)
        controller.update(chatID: "fixture", messages: rows(0..<60), revision: 1, isGroup: false, model: model,
                          style: .standard, unread: nil, jump: nil, scrollRequest: nil,
                          onReachTop: {}, onScrollState: { _ in })
        try await wait(controller)
        controller.hasNewer = true
        var asked = 0
        controller.onReachBottom = { asked += 1 }
        controller.scrollToBottom()
        controller.scrolled(Notification(name: NSView.boundsDidChangeNotification))
        try await Task.sleep(for: .milliseconds(20))
        #expect(asked >= 1)
        #expect(!controller.followsBottom)
    }
}
