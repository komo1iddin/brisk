import AppKit
import Testing
import ZapFastBridge
@testable import ZapFastCore
@testable import FeatureConversation

@MainActor
struct TimelineJournalRefreshTests {
    private func wait(_ controller: TimelineController) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.preparing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(!controller.preparing)
    }
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

    @Test(arguments: [true, false])
    func arrivalAndChangedRunBoundaryKeepTableHeightsAndPosition(follows: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-batched-arrival-\(UUID())")
        let model = AppModel(backend: PreviewBackend(), paths: AppPaths(data: folder, caches: folder))
        let controller = TimelineController()
        _ = controller.makeScrollView()
        controller.place(frame: CGRect(x: 0, y: 0, width: 600, height: 400), topInset: 20, bottomInset: 60)
        var messages = (0..<40).map(message)
        update(controller, messages, revision: 1, model: model)
        try await wait(controller)
        if follows { controller.scrollToBottom() }
        else { controller.clip.scroll(to: CGPoint(x: 0, y: 500)) }
        controller.followsBottom = follows
        let anchor = try #require(controller.readingAnchor())
        let untouched = try #require(controller.bubbleLayouts["m5"]?.layout)
        let generation = controller.generation
        messages[39].reactions = [ReactionInfo(sender: "other", fromMe: false, emoji: "👍")]
        messages.append(message(40))
        update(controller, messages, revision: 3,
               changes: [.init(revision: 2, previousCount: 40, count: 40, updated: [39]),
                         .init(revision: 3, previousCount: 40, count: 41, updated: [])], model: model)
        controller.tableView.layoutSubtreeIfNeeded()
        #expect(controller.generation == generation)
        #expect(controller.bubbleLayouts["m5"]?.layout === untouched)
        #expect(controller.tableView.numberOfRows == controller.items.count)
        for index in controller.items.indices {
            #expect(abs(controller.tableView.rect(ofRow: index).height - controller.items[index].height) < 0.5)
        }
        #expect(controller.message("m39")?.reactions.count == 1)
        #expect(controller.bubbleLayouts["m39"]?.source.endsRun == false)
        #expect(controller.bubbleLayouts["m40"]?.source.endsRun == true)
        if follows {
            #expect(controller.isAtBottom)
            #expect(controller.newBelow == 0)
        } else {
            let after = try #require(controller.readingAnchor())
            #expect(after.id == anchor.id && abs(after.offset - anchor.offset) < 0.5)
            #expect(controller.newBelow == 1)
        }
    }

    @Test func interiorDeletionPrunesItsLayoutEvenWhenBothWindowEdgesStay() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-cache-removal-\(UUID())")
        let model = AppModel(backend: PreviewBackend(), paths: AppPaths(data: folder, caches: folder))
        let controller = TimelineController()
        controller.makeScrollView().frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        var messages = (0..<40).map(message)
        update(controller, messages, revision: 1, model: model)
        try await wait(controller)
        #expect(controller.bubbleLayouts["m20"] != nil)
        messages.remove(at: 20)
        update(controller, messages, revision: 2, model: model)
        try await wait(controller)
        #expect(controller.bubbleLayouts["m20"] == nil)
        #expect(controller.hostedHeights["m20"] == nil)
        #expect(controller.message("m20") == nil)
        #expect(controller.messages.first?.id == "m0" && controller.messages.last?.id == "m39")
    }
}
