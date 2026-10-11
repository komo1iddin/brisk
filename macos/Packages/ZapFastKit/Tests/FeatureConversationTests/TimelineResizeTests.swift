import AppKit
import Testing
import ZapFastBridge
@testable import ZapFastCore
@testable import FeatureConversation

@MainActor
struct TimelineResizeTests {
    @Test(arguments: [780.0, 400.0])
    func widthChangesAndReflowKeepTheReadersMessage(width: Double) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-resize-\(UUID())")
        let model = AppModel(backend: PreviewBackend(), paths: AppPaths(data: folder, caches: folder))
        let controller = TimelineController()
        _ = controller.makeScrollView()
        controller.place(frame: CGRect(x: 0, y: 0, width: 760, height: 400), topInset: 20, bottomInset: 40)
        let messages = (0..<40).map { index in
            MessageRecord(id: "m\(index)", chat: "fixture", sender: "sender", senderName: nil, fromMe: false,
                          timestamp: 1_780_000_000 + Int64(index),
                          content: .text(text: String(repeating: "Synthetic resize fixture. ", count: 6), preview: nil),
                          status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
                          mentions: [], forwarded: false, thumbnail: nil, summary: "")
        }
        controller.update(chatID: "fixture", messages: messages, revision: 1, isGroup: false, model: model,
                          style: .standard, unread: nil, jump: nil, scrollRequest: nil, onReachTop: {}, onScrollState: { _ in })
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.preparing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        controller.clip.scroll(to: CGPoint(x: 0, y: 550))
        controller.followsBottom = false
        let anchor = try #require(controller.readingAnchor())
        controller.place(frame: CGRect(x: 0, y: 0, width: width, height: 400), topInset: 20, bottomInset: 40)
        controller.clipResized(Notification(name: NSView.frameDidChangeNotification))
        repeat { try await Task.sleep(for: .milliseconds(5)) }
        while (controller.preparing || controller.widthLimit != controller.currentWidthLimit()) && ContinuousClock.now < deadline
        #expect(!controller.preparing)
        let after = try #require(controller.readingAnchor())
        #expect(after.id == anchor.id)
        #expect(abs(after.offset - anchor.offset) < 0.5)
        controller.followsBottom = true
        controller.scrollToBottom()
        controller.place(frame: CGRect(x: 0, y: 0, width: width, height: 320), topInset: 20, bottomInset: 80)
        #expect(controller.isAtBottom)
    }
}
