import Foundation
import Testing
@testable import ZapFastCore

@MainActor
struct KeyboardTests {
    private func model() -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-keys-\(UUID().uuidString)")
        return AppModel(
            backend: PreviewBackend(),
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
    }

    @Test func chatsStepAsListedAndWrapAround() {
        let model = model()
        model.selectAdjacentChat(forward: true)
        #expect(model.selectedChatID == nil, "nothing listed, nothing to open")

        model.sidebarOrder = ["a", "b", "c"]
        model.selectAdjacentChat(forward: true)
        #expect(model.selectedChatID == "a")
        model.selectAdjacentChat(forward: false)
        #expect(model.selectedChatID == "c")
        model.selectAdjacentChat(forward: true)
        #expect(model.selectedChatID == "a")
    }

    @Test func scrollsAndFocusNeedAnOpenChat() {
        let model = model()
        model.scrollTimeline(.pageUp)
        model.focusComposer()
        #expect(model.timelineScroll == nil)
        #expect(model.composerFocusRequests == 0)

        model.selectedChatID = "a"
        model.scrollTimeline(.pageUp)
        let first = model.timelineScroll
        model.scrollTimeline(.pageUp)
        #expect(first?.kind == .pageUp)
        #expect(model.timelineScroll != first, "each press scrolls again")
    }
}
