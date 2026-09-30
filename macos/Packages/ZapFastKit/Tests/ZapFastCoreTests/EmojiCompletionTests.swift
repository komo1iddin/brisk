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

@MainActor
struct ComposerSettingsTests {
    @Test func typingIsToldOnlyWhenAllowed() {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-typing-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = AppModel(backend: backend, paths: AppPaths(data: root, caches: root), preferences: Preferences(defaults: defaults))
        #expect(model.preferences.enterSends && model.preferences.sendTyping)

        model.preferences.sendTyping = false
        model.composerEdited(in: "a@s.whatsapp.net")
        #expect(!backend.sent.contains { if case .composing = $0 { true } else { false } })

        model.preferences.sendTyping = true
        model.composerEdited(in: "a@s.whatsapp.net")
        #expect(backend.sent.last == .composing(chat: "a@s.whatsapp.net", composing: true))
        #expect(Preferences(defaults: defaults).sendTyping, "kept for the next launch")
    }
}
