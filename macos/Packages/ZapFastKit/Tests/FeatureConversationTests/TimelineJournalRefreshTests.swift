import AppKit
import Testing
import ZapFastBridge
@testable import ZapFastCore
@testable import FeatureConversation

@MainActor
struct TimelineJournalRefreshTests {
    private func message(_ index: Int) -> MessageRecord {
        MessageRecord(id: "m\(index)", chat: "fixture", sender: "sample", senderName: nil, fromMe: false,
                      timestamp: 1_780_000_000 + Int64(index) * 60, content: .text(text: "Synthetic \(index)", preview: nil),
                      status: .delivered, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
                      mentions: [], forwarded: false, thumbnail: nil, summary: "")
    }

    private func update(_ controller: TimelineController, _ messages: [MessageRecord], revision: Int,
                        changes: [ConversationDelta] = [], model: AppModel) {
        controller.update(chatID: "fixture", messages: messages, revision: revision, changes: changes,
                          isGroup: false, model: model, style: .standard, unread: nil, jump: nil, scrollRequest: nil,
                          onReachTop: {}, onScrollState: { _ in })
    }

    @Test func coalescedReceiptsReactionsAndAnArrivalKeepTheReadersPlaceAndSelection() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-coalesced-test-\(UUID().uuidString)")
        let model = AppModel(backend: PreviewBackend(), paths: AppPaths(data: folder, caches: folder))
        let controller = TimelineController()
        controller.makeScrollView().frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        var messages = (0..<40).map(message)
        update(controller, messages, revision: 1, model: model)
        let deadline = Date.now.addingTimeInterval(5)
        try await Task.sleep(for: .milliseconds(50))
        while controller.preparing, Date.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!controller.preparing)
        controller.clip.scroll(to: NSPoint(x: 0, y: 500))
        controller.followsBottom = false
        let anchor = try #require(controller.readingAnchor())
        let generation = controller.generation
        let count = controller.items.count
        model.select(messages[5])

        messages[12].reactions = [ReactionInfo(sender: "other", fromMe: false, emoji: "👍")]
        messages[20].status = .read
        messages.append(message(40))
        let changes = [ConversationDelta(revision: 2, previousCount: 40, count: 40, updated: [12]),
                       ConversationDelta(revision: 3, previousCount: 40, count: 40, updated: [20]),
                       ConversationDelta(revision: 4, previousCount: 40, count: 41, updated: [])]
        update(controller, messages, revision: 4, changes: changes, model: model)

        #expect(controller.generation == generation)
        #expect(controller.items.count == count + 1)
        #expect(controller.message("m12")?.reactions.count == 1)
        #expect(controller.message("m20")?.status == .read)
        #expect(controller.message("m40") != nil)
        #expect(controller.newBelow == 1)
        #expect(controller.selectionState(forMessage: "m5").selected)
        let after = try #require(controller.readingAnchor())
        #expect(after.id == anchor.id)
        #expect(abs(after.offset - anchor.offset) < 0.5)
    }
}
