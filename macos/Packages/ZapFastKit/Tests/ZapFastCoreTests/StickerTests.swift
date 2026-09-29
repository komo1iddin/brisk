import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct StickerTests {
    private func model(giphyKey: String = "") -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-sticker-\(UUID().uuidString)")
        let preferences = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        preferences.giphyKey = giphyKey
        return (AppModel(backend: backend, paths: AppPaths(data: root, caches: root), preferences: preferences), backend)
    }

    private func library(favorites: [String] = []) -> StickerLibrary {
        StickerLibrary(favorites: favorites, packs: [], recent: ["/r.webp"], received: [], emojis: [])
    }

    private func gif(_ id: String) -> GifInfo {
        GifInfo(id: id, still: nil, mp4: "https://example.invalid/\(id).mp4", width: 100, height: 100)
    }

    @Test func aStickerRepliesWhenAReplyIsOpen() {
        let (model, backend) = model()
        let quoted = MessageRecord(
            id: "q", chat: "c", sender: "x", senderName: nil, fromMe: false, timestamp: 1,
            content: .text(text: "hi", preview: nil), status: .none, deliveredAt: nil, readAt: nil,
            quoted: nil, reactions: [], edited: false, mentions: [], forwarded: false, thumbnail: nil, summary: "hi"
        )
        model.reply(to: quoted)
        model.sendSticker("/s.webp", in: "c")
        #expect(backend.sent.last == .sendSticker(chat: "c", path: "/s.webp", quoting: "q"))
        #expect(model.replyingTo["c"] == nil)
    }

    @Test func favoriteTogglesBySavingOrForgetting() {
        let (model, backend) = model()
        model.apply([.stickers(library: library(favorites: ["/f.webp"]))])
        model.toggleFavoriteSticker("/f.webp")
        model.toggleFavoriteSticker("/r.webp")
        #expect(backend.sent.suffix(2) == [.forgetSticker(path: "/f.webp"), .saveSticker(path: "/r.webp")])
    }

    @Test func gifAnswersToAnEarlierQueryAreIgnored() {
        let (model, _) = model(giphyKey: "key")
        model.searchGifs("ca")
        model.searchGifs("cat")
        model.apply([.gifs(query: "ca", gifs: [gif("a")], error: nil)])
        #expect(model.stickers.gifs.isEmpty)
        #expect(model.stickers.gifPending)

        model.apply([.gifs(query: "cat", gifs: [gif("b")], error: nil)])
        #expect(model.stickers.gifs.map(\.id) == ["b"])
        #expect(!model.stickers.gifPending)
    }
}
