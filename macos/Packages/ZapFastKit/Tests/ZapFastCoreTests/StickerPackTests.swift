import CoreGraphics
import Foundation
import ImageIO
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

@MainActor
struct OwnStickerTests {
    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-own-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        return (model, backend)
    }

    @Test func packsAreMadeFilledAndDeleted() {
        let (model, backend) = model()
        model.createStickerPack(named: "   ")
        #expect(backend.sent.isEmpty)
        model.createStickerPack(named: " Mine ")
        #expect(backend.sent.last == .createStickerPack(name: "Mine"))

        let own = StickerPackInfo(name: "Mine", dir: "/packs/mine", stickers: [], local: true)
        let imported = StickerPackInfo(name: "Cats", dir: "/packs/cats", stickers: [], local: false)
        model.setSticker("/s/a.webp", in: own, member: true)
        #expect(backend.sent.last == .setStickerPack(pack: "/packs/mine", sticker: "/s/a.webp", member: true))
        let before = backend.sent.count
        model.setSticker("/s/a.webp", in: imported, member: true)
        #expect(backend.sent.count == before, "only our own packs take stickers")

        model.deleteStickerPack(imported)
        #expect(backend.sent.last == .deleteStickerPack(dir: "/packs/cats"))
    }

    @Test func aMadeStickerKeepsTransparencyOnlyWhenThereIsSome() {
        let (model, backend) = model()
        let opaque = StickerPicture(url: URL(filePath: "/p/a.jpg"), width: 800, height: 600, transparent: false)
        let crop = centeredStickerCrop(width: 800, height: 600)
        #expect(crop == StickerCropInfo(x: 100, y: 0, side: 600))

        model.makeSticker(from: opaque, crop: crop, keepTransparency: true, emojis: ["😀"], sendTo: nil)
        #expect(backend.sent.last == .makeSticker(source: "/p/a.jpg", crop: crop, transparent: false, emojis: ["😀"], chat: nil))

        let cutout = StickerPicture(url: URL(filePath: "/p/b.png"), width: 512, height: 512, transparent: true)
        model.makeSticker(from: cutout, crop: crop, keepTransparency: true, emojis: [], sendTo: "c@s.whatsapp.net")
        #expect(backend.sent.last == .makeSticker(source: "/p/b.png", crop: crop, transparent: true, emojis: [], chat: "c@s.whatsapp.net"))
    }

    @Test func picturesAreInspected() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "zapfast-pic-\(UUID().uuidString).png")
        let context = try #require(CGContext(
            data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let picture = try #require(await StickerPicture.inspect(url))
        #expect(picture.width == 4 && picture.height == 2)
        #expect(picture.transparent, "half of it is clear")
        #expect(await StickerPicture.inspect(URL(filePath: "/nonexistent.png")) == nil)
    }
}
