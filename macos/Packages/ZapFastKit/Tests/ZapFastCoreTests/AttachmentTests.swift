import CoreGraphics
import Foundation
import Testing
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
        model.stage(files: [URL(filePath: "/tmp/a.pdf"), URL(filePath: "/tmp/b.jpg")], in: chat)
        #expect(model.attachments[chat]?.count == 2)
        #expect(backend.sent.allSatisfy { if case .sendFiles = $0 { false } else { true } })

        model.reply(to: message("q"))
        model.composerText[chat] = "  look  "
        model.sendText(in: chat)

        #expect(backend.sent.last == .sendFiles(
            chat: chat, paths: ["/tmp/a.pdf", "/tmp/b.jpg"], caption: "look", mentions: [], quoting: "q"
        ))
        #expect(model.attachments[chat] == nil)
        #expect(model.composerText[chat] == "")
        #expect(model.replyingTo[chat] == nil)
    }

    @Test func aPastedImageGoesFirstWithTheCaptionAndFilesFollowBare() {
        let (model, backend) = model()
        model.stage(image: pixel, in: chat)
        model.stage(files: [URL(filePath: "/tmp/a.pdf")], in: chat)
        model.sendText(in: chat)

        let sends = backend.sent.filter {
            switch $0 { case .sendImage, .sendFiles: true; default: false }
        }
        #expect(sends == [
            .sendImage(chat: chat, width: 1, height: 1, rgba: Data([1, 2, 3, 4]), caption: nil, mentions: [], quoting: nil),
            .sendFiles(chat: chat, paths: ["/tmp/a.pdf"], caption: nil, mentions: [], quoting: nil),
        ])
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
            files: ["/tmp/a.pdf"], image: pixel, caption: "look"
        )])
        #expect(model.attachments[chat]?.count == 2)
        #expect(model.composerText[chat] == "look")
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
