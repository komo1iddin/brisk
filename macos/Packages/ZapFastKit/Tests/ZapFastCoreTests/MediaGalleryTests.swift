import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct MediaGalleryTests {
    private let chat = "c@s.whatsapp.net"
    private let media = MediaInfo(mime: "image/jpeg", size: 1, width: 10, height: 10, path: nil)

    private func message(_ id: String, _ content: MessageContent, at timestamp: Int64 = 1) -> MessageRecord {
        MessageRecord(
            id: id, chat: chat, sender: "a@s.whatsapp.net", senderName: nil, fromMe: false, timestamp: timestamp,
            content: content, status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: nil, summary: ""
        )
    }

    @Test func onlyPhotosVideosAndGifsAreShown() {
        let messages = [
            message("photo", .image(caption: nil, media: media)),
            message("video", .video(caption: nil, media: media, seconds: 3, gif: false, note: false)),
            message("gif", .video(caption: nil, media: media, seconds: nil, gif: true, note: false)),
            message("note", .video(caption: nil, media: media, seconds: 3, gif: false, note: true)),
            message("sticker", .sticker(media: media, animated: false)),
            message("text", .text(text: "hi", preview: nil)),
        ]
        #expect(MediaGallery.items(in: messages).map(\.id) == ["photo", "video", "gif"])
        #expect(MediaGallery.kind(of: messages[2]) == .gif)
        #expect(MediaGallery.kind(of: messages[3]) == nil, "a round video message plays in its bubble")
    }

    @Test func blankCaptionsAreNone() {
        #expect(MediaGallery.caption(of: message("a", .image(caption: "  \n", media: media))) == nil)
        #expect(MediaGallery.caption(of: message("b", .image(caption: "look", media: media))) == "look")
    }

    @Test func monthsRunNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let january = message("jan", .image(caption: nil, media: media), at: 1_704_067_200 + 86_400)
        let march = message("mar", .image(caption: nil, media: media), at: 1_709_251_200 + 86_400)
        let months = MediaGallery.months(of: [january, march], calendar: calendar)
        #expect(months.map { $0.items.map(\.id) } == [["mar"], ["jan"]])
    }

    @Test func openingTheViewerStopsTheBubblesVideoAndLeavingTheChatClosesIt() {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-viewer-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend, paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        model.selectedChatID = chat
        model.openMediaViewer(message("text", .text(text: "hi", preview: nil)))
        #expect(model.mediaViewer == nil, "text has nothing to view")
        model.openMediaViewer(message("photo", .image(caption: nil, media: media)))
        #expect(model.mediaViewer == MediaViewerRequest(chat: chat, message: "photo"))
        model.selectedChatID = "other@s.whatsapp.net"
        #expect(model.mediaViewer == nil)
    }
}
