import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct VideoTests {
    private let chat = "c@s.whatsapp.net"

    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-video-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        return (model, backend)
    }

    private func video(_ id: String, path: String?, gif: Bool = false) -> MessageRecord {
        MessageRecord(
            id: id, chat: chat, sender: "a@s.whatsapp.net", senderName: nil, fromMe: false, timestamp: 1,
            content: .video(
                caption: nil,
                media: MediaInfo(mime: "video/mp4", size: 10, width: 320, height: 240, path: path),
                seconds: 3, gif: gif, note: false
            ),
            status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: nil, summary: "Video"
        )
    }

    @Test func aVideoAskedForPlaysOnceItsDownloadLands() {
        let (model, _) = model()
        model.selectedChatID = chat
        model.apply([.messages(chat: chat, messages: [video("v", path: nil), video("w", path: nil)], older: false, complete: true)])
        model.playVideo(video("v", path: nil))
        let file = FileManager.default.temporaryDirectory.appending(path: "v.mp4").path(percentEncoded: false)

        // Another download landing does not start it.
        model.apply([.media(chat: chat, message: "w", card: nil, path: file, error: nil)])
        #expect(model.video.current == nil)

        model.apply([.media(chat: chat, message: "v", card: nil, path: file, error: nil)])
        #expect(model.video.current == MessageKey(chat: chat, message: "v"))
    }

    @Test func aFailedOrAbandonedDownloadStartsNothing() {
        let (model, _) = model()
        model.selectedChatID = chat
        model.apply([.messages(chat: chat, messages: [video("v", path: nil)], older: false, complete: true)])
        model.playVideo(video("v", path: nil))
        model.apply([.media(chat: chat, message: "v", card: nil, path: nil, error: "gone")])
        #expect(model.video.current == nil)

        model.playVideo(video("v", path: nil))
        model.selectedChatID = "other@s.whatsapp.net"
        model.selectedChatID = chat
        model.apply([.media(chat: chat, message: "v", card: nil, path: "/tmp/v.mp4", error: nil)])
        #expect(model.video.current == nil)
    }

    @Test func aClickedNotificationLandsOnItsMessage() {
        let (model, _) = model()
        model.open(notified: MessageKey(chat: chat, message: "v"))
        #expect(model.selectedChatID == chat)
        model.apply([.messages(chat: chat, messages: [video("v", path: nil)], older: false, complete: true)])
        #expect(model.jump?.key == MessageKey(chat: chat, message: "v"))
    }

    @Test func aVideoNotHereYetDownloadsInsteadOfPlaying() {
        let (model, backend) = model()
        model.playVideo(video("v", path: nil))
        #expect(backend.sent.last == .download(chat: chat, message: "v", card: nil))
        #expect(model.video.current == nil)
    }

    @Test func oneVideoPlaysAtATimeAndStopsWithItsChat() {
        let (model, _) = model()
        model.selectedChatID = chat
        model.playVideo(video("a", path: "/tmp/zapfast-none-a.mp4"))
        #expect(model.video.current == MessageKey(chat: chat, message: "a"))
        model.playVideo(video("b", path: "/tmp/zapfast-none-b.mp4"))
        #expect(model.video.current == MessageKey(chat: chat, message: "b"))

        model.selectedChatID = "other@s.whatsapp.net"
        #expect(model.video.current == nil)
    }
}
