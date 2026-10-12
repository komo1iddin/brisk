import AppKit
import Testing
import ZapFastBridge
@testable import FeatureConversation
@testable import ZapFastCore

@MainActor
@Suite(.serialized)
struct TimelineResizeCoalescingTests {
    private func fixture() async throws -> (TimelineController, AppModel) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-width-burst-\(UUID())")
        let model = AppModel(backend: PreviewBackend(), paths: AppPaths(data: folder, caches: folder),
                             preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        let controller = TimelineController()
        _ = controller.makeScrollView()
        controller.place(frame: CGRect(x: 0, y: 0, width: 760, height: 400), topInset: 20, bottomInset: 40)
        let rows = (0..<80).map { index in
            MessageRecord(id: "m\(index)", chat: "fixture", sender: "sender", senderName: nil, fromMe: false,
                timestamp: Int64(index), content: .text(text: String(repeating: "Synthetic wrapped text. ", count: 8), preview: nil),
                status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
                mentions: [], forwarded: false, thumbnail: nil, summary: "")
        }
        controller.update(chatID: "fixture", messages: rows, revision: 1, isGroup: false, model: model,
                          style: .standard, unread: nil, jump: nil, scrollRequest: nil, onReachTop: {}, onScrollState: { _ in })
        try await settled(controller)
        return (controller, model)
    }

    private func width(_ width: CGFloat, in controller: TimelineController) {
        controller.place(frame: CGRect(x: 0, y: 0, width: width, height: 400), topInset: 20, bottomInset: 40)
        controller.clipResized(Notification(name: NSView.frameDidChangeNotification))
    }

    private func settled(_ controller: TimelineController) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat { try await Task.sleep(for: .milliseconds(5)) }
        while (controller.preparing || controller.widthRelayoutTask != nil || controller.widthCheckScheduled
               || controller.widthLimit != controller.currentWidthLimit()) && ContinuousClock.now < deadline
        try #require(!controller.preparing && controller.widthLimit == controller.currentWidthLimit())
    }

    @Test func aRapidWidthBurstMeasuresOnceAndKeepsTheReadingAnchor() async throws {
        let (controller, model) = try await fixture()
        defer { withExtendedLifetime(model) {} }
        controller.clip.scroll(to: CGPoint(x: 0, y: 500))
        controller.followsBottom = false
        let anchor = try #require(controller.readingAnchor())
        let generation = controller.generation
        for index in 1...10 {
            width(760 - CGFloat(index * 20), in: controller)
            try await Task.sleep(for: .milliseconds(8))
        }
        #expect(controller.generation == generation)
        try await settled(controller)
        #expect(controller.generation == generation + 1)
        let after = try #require(controller.readingAnchor())
        #expect(after.id == anchor.id && abs(after.offset - anchor.offset) < 0.5)
    }

    @Test func returningToTheMeasuredWidthCancelsTransientReflows() async throws {
        let (controller, model) = try await fixture()
        defer { withExtendedLifetime(model) {} }
        let generation = controller.generation
        width(500, in: controller)
        try await Task.sleep(for: .milliseconds(10))
        width(760, in: controller)
        try await settled(controller)
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.generation == generation)
        #expect(controller.widthRelayoutTask == nil)
    }

    @Test func endingLiveResizeFlushesAPendingWidthWithoutTheDelay() async throws {
        let (controller, model) = try await fixture()
        defer { withExtendedLifetime(model) {} }
        let generation = controller.generation
        width(500, in: controller)
        try await Task.sleep(for: .milliseconds(10))
        try #require(controller.widthRelayoutTask != nil)
        controller.liveResizeEnded()
        #expect(controller.generation == generation + 1)
        #expect(controller.widthRelayoutTask == nil)
        try await settled(controller)
        #expect(controller.generation == generation + 1)
    }
}
