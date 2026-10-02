import AppKit
import Foundation
import Testing
@testable import FeatureConversation
@testable import ZapFastCore

/// A Lottie sticker's file is a `.was` zip; the view unpacks it, parses the
/// animation inside and shows its first frame.
@MainActor
struct LottieStickerTests {
    /// A red square that turns once: the smallest animation Lottie accepts.
    static let animation = """
    {"v":"5.7.0","fr":30,"ip":0,"op":60,"w":200,"h":200,"nm":"square","ddd":0,"assets":[],
     "layers":[{"ddd":0,"ind":1,"ty":4,"nm":"square","sr":1,
       "ks":{"o":{"a":0,"k":100},
             "r":{"a":1,"k":[{"t":0,"s":[0],"i":{"x":[0.5],"y":[1]},"o":{"x":[0.5],"y":[0]}},{"t":60,"s":[360]}]},
             "p":{"a":0,"k":[100,100,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
       "ao":0,
       "shapes":[{"ty":"gr","it":[
         {"ty":"rc","d":1,"s":{"a":0,"k":[100,100]},"p":{"a":0,"k":[0,0]},"r":{"a":0,"k":0}},
         {"ty":"fl","c":{"a":0,"k":[1,0.2,0.2,1]},"o":{"a":0,"k":100}},
         {"ty":"tr","p":{"a":0,"k":[0,0]},"a":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}],
       "ip":0,"op":60,"st":0,"bm":0}],"markers":[]}
    """

    private func sticker(animation json: String?) throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-lottie-test-\(UUID().uuidString)")
        let source = root.appending(path: "source/animation", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data((json ?? "unused").utf8).write(to: source.appending(path: json == nil ? "notes.txt" : "animation_secondary.json"))
        let file = root.appending(path: "chat-id.was")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn",
                             root.appending(path: "source").path(percentEncoded: false), file.path(percentEncoded: false)]
        try process.run()
        process.waitUntilExit()
        return (root, file)
    }

    @Test func aStickerLoadsAndIsReadyToMove() async throws {
        let (root, file) = try sticker(animation: Self.animation)
        defer { try? FileManager.default.removeItem(at: root) }
        let view = LottieStickerView(frame: NSRect(x: 0, y: 0, width: 160, height: 160))
        #expect(!view.isReady)
        #expect(await view.load(file: file, cache: root.appending(path: "cache")))
        #expect(view.isReady)
        // Playing and stopping an animation that is ready is harmless.
        view.setPlaying(true)
        view.setPlaying(false)
    }

    @Test func aFileWithoutAnAnimationIsNotReady() async throws {
        let (root, file) = try sticker(animation: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let view = LottieStickerView(frame: .zero)
        #expect(await view.load(file: file, cache: root.appending(path: "cache")) == false)
        #expect(!view.isReady)
        view.setPlaying(true)
    }

    @Test func aFileThatIsNotAnimationJSONIsNotReady() async throws {
        let (root, file) = try sticker(animation: "this is not json")
        defer { try? FileManager.default.removeItem(at: root) }
        let view = LottieStickerView(frame: .zero)
        #expect(await view.load(file: file, cache: root.appending(path: "cache")) == false)
    }

    @Test func aMissingFileIsNotReady() async {
        let view = LottieStickerView(frame: .zero)
        let missing = FileManager.default.temporaryDirectory.appending(path: "no-such-\(UUID().uuidString).was")
        #expect(await view.load(file: missing, cache: FileManager.default.temporaryDirectory) == false)
    }

    @Test func aStickerIsLottieByItsMimetype() {
        func picture(_ kind: BubbleSource.Picture.Kind, mime: String) -> BubbleSource.Picture {
            BubbleSource.Picture(kind: kind, width: nil, height: nil, path: nil, mime: mime, bytes: 0, seconds: nil, thumbnail: nil)
        }
        #expect(picture(.animatedSticker, mime: "application/was").isLottie)
        #expect(picture(.animatedSticker, mime: "Application/WAS; charset=binary").isLottie)
        #expect(!picture(.animatedSticker, mime: "image/webp").isLottie)
        // Only stickers: a photo with a stray mimetype is still a photo.
        #expect(!picture(.photo, mime: "application/was").isLottie)
    }
}
