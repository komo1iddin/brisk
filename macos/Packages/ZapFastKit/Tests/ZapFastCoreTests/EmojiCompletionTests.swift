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
        #expect(model.preferences.enterSends && model.accountPreferences.sendTyping)

        model.accountPreferences.sendTyping = false
        model.composerEdited(in: "a@s.whatsapp.net")
        #expect(!backend.sent.contains { if case .composing = $0 { true } else { false } })

        model.accountPreferences.sendTyping = true
        model.composerEdited(in: "a@s.whatsapp.net")
        #expect(backend.sent.last == .composing(chat: "a@s.whatsapp.net", composing: true))
        #expect(AccountPreferences(defaults: defaults).sendTyping, "kept for the next launch")
    }
}

@MainActor
struct ReactionTests {
    private let chat = "c@s.whatsapp.net"

    private func message(mine: String? = nil) -> MessageRecord {
        MessageRecord(
            id: "m", chat: chat, sender: "a@s.whatsapp.net", senderName: nil, fromMe: false,
            timestamp: 1, content: .text(text: "hi", preview: nil), status: .none,
            deliveredAt: nil, readAt: nil, quoted: nil,
            reactions: mine.map { [ReactionInfo(sender: "me@s.whatsapp.net", fromMe: true, emoji: $0)] } ?? [],
            edited: false, mentions: [], forwarded: false, thumbnail: nil, summary: "hi"
        )
    }

    @Test func theMostUsedReactionsComeFirst() {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-react-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend, paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        #expect(model.quickReactions(for: message()) == ["👍", "❤️", "😂", "😮", "😢", "🙏"])

        model.showReactionPicker(for: message())
        model.react("🔥", to: message())
        model.react("🎉", to: message())
        model.react("🔥", to: message())
        #expect(model.reactionTarget == nil)
        #expect(backend.sent.last == .react(chat: chat, message: "m", emoji: "🔥"))
        #expect(model.preferences.reactionEmoji.map(\.emoji) == ["🔥", "🎉"])
        #expect(model.preferences.reactionEmoji.first?.count == 2)
        #expect(model.quickReactions(for: message(mine: "🦄")).prefix(2) == ["🔥", "🎉"])
        #expect(model.quickReactions(for: message(mine: "🦄")).last == "🦄")

        // Taking ours back counts for nothing.
        model.react("", to: message())
        #expect(model.preferences.reactionEmoji.count == 2)
    }
}
