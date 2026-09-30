import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct EmojiCompletionTests {
    private func model() -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-emoji-\(UUID().uuidString)")
        return AppModel(
            backend: PreviewBackend(),
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
    }

    @Test func shortcodesCompleteAsUpstreams() {
        let model = model()
        #expect(model.emojiSuggestions(for: "grinning").first?.emoji == "😀")
        #expect(model.emojiSuggestions(for: "thumbsup").contains { $0.emoji == "👍" })
    }

    @Test func pickedEmojiComeFirstForABareColon() {
        let model = model()
        model.rememberEmoji("🚀")
        model.rememberEmoji("😀")
        model.rememberEmoji("🚀")
        #expect(model.preferences.recentEmoji == ["🚀", "😀"])
        #expect(model.emojiSuggestions(for: "").prefix(2).map(\.emoji) == ["🚀", "😀"])
        for index in 0..<40 { model.rememberEmoji(String(UnicodeScalar(0x1F600 + index)!)) }
        #expect(model.preferences.recentEmoji.count == 36)
    }
}
