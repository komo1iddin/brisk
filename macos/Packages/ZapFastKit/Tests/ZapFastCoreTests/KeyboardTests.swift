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

    @Test func commandNumbersOpenTheFirstNineChats() {
        let model = model()
        model.sidebarOrder = (1...12).map { "chat\($0)" }
        #expect(model.sidebarShortcuts.count == 9)
        model.selectChat(atSidebarPlace: 2)
        #expect(model.selectedChatID == "chat3")
        model.selectChat(atSidebarPlace: 20)
        #expect(model.selectedChatID == "chat3", "no chat there, nothing changes")
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

@MainActor
struct TextSizeTests {
    @Test func textGrowsAndShrinksByTenthsWithinItsRange() {
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-size-\(UUID().uuidString)")
        let model = AppModel(
            backend: PreviewBackend(), paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        #expect(model.preferences.textScale == 1)
        model.changeTextSize(bigger: true)
        #expect(model.preferences.textScale == 1.1)
        for _ in 0..<20 { model.changeTextSize(bigger: true) }
        #expect(model.preferences.textScale == 1.6)
        #expect(!model.canMakeTextBigger)
        for _ in 0..<20 { model.changeTextSize(bigger: false) }
        #expect(model.preferences.textScale == 0.8)
        model.resetTextSize()
        #expect(model.preferences.textScale == 1)
    }
}
