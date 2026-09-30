import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct AttachmentTests {
    private let chat = "c@s.whatsapp.net"

    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-attach-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        model.selectedChatID = chat
        return (model, backend)
    }

    private let pixel = PastedImage(width: 1, height: 1, rgba: Data([1, 2, 3, 4]))

    private func message(_ id: String) -> MessageRecord {
        MessageRecord(
            id: id, chat: chat, sender: "a@s.whatsapp.net", senderName: nil, fromMe: false, timestamp: 1,
            content: .text(text: "hi", preview: nil), status: .none, deliveredAt: nil, readAt: nil,
            quoted: nil, reactions: [], edited: false, mentions: [], forwarded: false, thumbnail: nil, summary: "hi"
        )
    }

    @Test func stagedFilesWaitForSendAndTakeTheCaptionAndReply() {
        let (model, backend) = model()
        model.stage(files: [URL(filePath: "/tmp/a.pdf"), URL(filePath: "/tmp/b.zip")], in: chat)
        #expect(model.attachments[chat]?.count == 2)
        #expect(backend.sent.allSatisfy { if case .sendFiles = $0 { false } else { true } })

        model.reply(to: message("q"))
        model.composerText[chat] = "  look  "
        model.sendText(in: chat)

        #expect(backend.sent.last == .sendFiles(
            chat: chat, paths: ["/tmp/a.pdf", "/tmp/b.zip"], caption: "look", mentions: [], quoting: "q"
        ))
        #expect(model.attachments[chat] == nil)
        #expect(model.composerText[chat] == "")
        #expect(model.replyingTo[chat] == nil)
    }

    @Test func photosOpenTheEditorAndTakeTheTypedTextAsTheirCaption() {
        let (model, _) = model()
        model.composerText[chat] = "look"
        model.stage(files: [URL(filePath: "/tmp/a.pdf")], in: chat)
        #expect(!model.isEditingMedia(in: chat), "a document waits in the strip")
        #expect(model.composerText[chat] == "look")

        model.stage(image: pixel, in: chat)
        #expect(model.isEditingMedia(in: chat))
        #expect(model.attachments[chat]?.map(\.caption) == ["look", ""])
        #expect(model.composerText[chat] == "")

        model.discardAttachments(in: chat)
        #expect(model.attachments[chat] == nil)
        #expect(model.composerText[chat] == "look", "discarding keeps what was typed")
    }

    @Test func mediaGoesOneByOneWithItsOwnCaptionAndTheReplyOnTheFirst() async throws {
        let (model, backend) = model()
        let photo = try Self.picture(width: 2400, height: 1200)
        model.stage(files: [photo, URL(filePath: "/tmp/a.pdf")], in: chat)
        let staged = try #require(model.attachments[chat])
        #expect(staged.map(\.media) == [.photo, .none])
        model.setCaption("one", for: staged[0].id, in: chat)
        model.setCaption("two", for: staged[1].id, in: chat)
        var edit = MediaEdit()
        edit.rotateLeft()
        model.setEdit(edit, for: staged[0].id, in: chat)
        model.reply(to: message("q"))

        model.sendText(in: chat)
        #expect(model.attachments[chat] == nil)
        #expect(model.preparingMedia[chat] == 2)
        for _ in 0..<200 where model.preparingMedia[chat] != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.preparingMedia[chat] == nil)

        let sends = backend.sent.compactMap { command -> (paths: [String], caption: String?, quoting: String?)? in
            if case let .sendFiles(_, paths, caption, _, quoting) = command { (paths, caption, quoting) } else { nil }
        }
        try #require(sends.count == 2)
        #expect(sends[0].caption == "one" && sends[0].quoting == "q")
        #expect(sends[1].paths == ["/tmp/a.pdf"] && sends[1].caption == "two" && sends[1].quoting == nil)

        // The photo was turned and brought to standard quality, as a JPEG.
        let sent = URL(filePath: try #require(sends[0].paths.first))
        #expect(sent.pathExtension == "jpg")
        let source = try #require(CGImageSourceCreateWithURL(sent as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 800)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 1600)
    }

    /// A PNG on disk, red on the left half and blue on the right.
    static func picture(width: Int, height: Int) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appending(path: "zapfast-picture-\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func removingAndLeavingTheChatDropsThem() {
        let (model, _) = model()
        model.stage(files: [URL(filePath: "/tmp/a.pdf")], in: chat)
        model.stage(files: [URL(filePath: "/tmp/b.pdf")], in: chat)
        model.removeAttachment(model.attachments[chat]![0].id, in: chat)
        #expect(model.attachments[chat]?.compactMap(\.fileURL?.lastPathComponent) == ["b.pdf"])

        model.selectedChatID = "other@s.whatsapp.net"
        #expect(model.attachments[chat] == nil)
    }

    @Test func refusedAttachmentsComeBackWithTheirCaption() {
        let (model, _) = model()
        model.apply([.sendRefused(
            chat: chat, quoting: nil, reason: .offline, text: nil,
            files: ["/tmp/a.pdf"], image: pixel, caption: "look", voice: []
        )])
        #expect(model.attachments[chat]?.count == 2)
        // The pasted picture reopens the editor, with the caption on the first.
        #expect(model.isEditingMedia(in: chat))
        #expect(model.attachments[chat]?.first?.caption == "look")
        #expect(model.composerText[chat] == "")
        #expect(model.unsentVoice == nil)
    }

    @Test func aRefusedVoiceMessageWaitsToBeSentAgainOrDiscarded() {
        let (model, backend) = model()
        let samples = [Float](repeating: 0.1, count: Int(voiceSampleRate()) * 3)
        model.apply([.sendRefused(
            chat: chat, quoting: nil, reason: .offline, text: nil,
            files: [], image: nil, caption: nil, voice: samples
        )])
        #expect(model.unsentVoice?.chat == chat)
        #expect(model.unsentVoice?.seconds == 3)

        model.resendVoice(in: "other@s.whatsapp.net")
        #expect(model.unsentVoice != nil, "it belongs to its own chat")
        model.resendVoice(in: chat)
        #expect(backend.sent.last == .sendVoice(chat: chat, samples: samples, quoting: nil))
        #expect(model.unsentVoice == nil)

        model.apply([.sendRefused(
            chat: chat, quoting: nil, reason: .offline, text: nil,
            files: [], image: nil, caption: nil, voice: samples
        )])
        model.discardUnsentVoice()
        #expect(model.unsentVoice == nil)
    }

    @Test func pastedPicturesBecomeStraightAlpha() throws {
        // One half-transparent red pixel.
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let picture = try #require(context.makeImage())
        let image = try #require(PastedImage(picture))
        #expect(image.width == 1 && image.height == 1)
        #expect(image.rgba[0] >= 250 && image.rgba[3] >= 126 && image.rgba[3] <= 129)
    }
}
