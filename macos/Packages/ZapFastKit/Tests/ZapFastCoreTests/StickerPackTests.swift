import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct StickerPackTests {
    private let chat = "c@s.whatsapp.net"

    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-packs-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        model.apply([.link(state: .connected)])
        return (model, backend)
    }

    private var shared: MessageRecord {
        MessageRecord(
            id: "p", chat: chat, sender: chat, senderName: nil, fromMe: false, timestamp: 1,
            content: .stickerPack(name: "Cats", publisher: "Aziza", count: 2, caption: nil),
            status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: nil, summary: "Cats"
        )
    }

    private let pack = StickerPackInfo(name: "Cats", dir: "/cache/stickers/view/p", stickers: ["/a.webp", "/b.webp"], local: false)

    @Test func aSharedPackIsFetchedShownAndAdded() {
        let (model, backend) = model()
        model.viewStickerPack(shared)
        #expect(backend.sent.last == .viewStickerPack(chat: chat, message: "p"))
        #expect(model.stickerPackPreview?.state == .loading)

        model.apply([.stickerPackPreview(pack: pack, publisher: "Aziza", error: nil)])
        #expect(model.stickerPackPreview?.state == .ready(pack: pack, publisher: "Aziza"))

        model.addViewedStickerPack()
        #expect(backend.sent.last == .addStickerPack(dir: "/cache/stickers/view/p", name: "Cats"))
        #expect(model.stickerPackPreview == nil)
    }

    @Test func aPackThatWillNotOpenSaysWhy() {
        let (model, _) = model()
        model.viewStickerPack(shared)
        model.apply([.stickerPackPreview(pack: nil, publisher: nil, error: "This sticker pack is no longer available")])
        #expect(model.stickerPackPreview?.state == .failed("This sticker pack is no longer available"))
    }

    @Test func anAnswerNobodyWaitsForIsIgnored() {
        let (model, _) = model()
        model.apply([.stickerPackPreview(pack: pack, publisher: "Aziza", error: nil)])
        #expect(model.stickerPackPreview == nil)
    }

    @Test func ourPacksGoOutAsPackMessages() {
        let (model, backend) = model()
        model.sendStickerPack(pack, in: chat)
        #expect(backend.sent.last == .sendStickerPack(chat: chat, dir: "/cache/stickers/view/p"))
    }
}
