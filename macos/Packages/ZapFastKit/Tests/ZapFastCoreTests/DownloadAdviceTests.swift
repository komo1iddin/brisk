import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

/// A download the person asked for says why it failed; one that began by
/// itself fails quietly.
@MainActor
struct DownloadAdviceTests {
    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-advice-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        return (model, backend)
    }

    private func failed(_ message: MessageRecord, _ error: String) -> BridgeEvent {
        .media(chat: message.chat, message: message.id, card: nil, path: nil, error: error)
    }

    @Test func aDownloadTheMessageAskedForExplainsItsFailure() {
        let (model, _) = model()
        let file = Records.document("a")
        model.download(file)
        model.apply([failed(file, "Your phone did not answer. Open WhatsApp on it and try again")])
        #expect(model.notices.last?.text.contains("Open WhatsApp on your phone") == true)
        #expect(model.conversations.download(MessageKey(chat: file.chat, message: file.id))?.failure == .phoneSilent)
    }

    @Test func aDownloadThatBeganByItselfFailsQuietly() {
        let (model, _) = model()
        model.accountPreferences.autoDownload = true
        let file = Records.document("a")
        model.autoDownload(file)
        model.apply([failed(file, "No longer available on WhatsApp's servers")])
        #expect(model.notices.isEmpty)
        #expect(model.conversations.download(MessageKey(chat: file.chat, message: file.id))?.failure == .gone)
    }

    @Test func aSuccessLeavesNoNoticeAndForgetsTheRequest() {
        let (model, _) = model()
        let file = Records.document("a")
        model.download(file)
        model.apply([.media(chat: file.chat, message: file.id, card: nil, path: "/tmp/a.pdf", error: nil)])
        #expect(model.notices.isEmpty)
        // A later failure of an automatic retry is not blamed on that click.
        model.accountPreferences.autoDownload = true
        model.autoDownload(file)
        model.apply([failed(file, "Download timed out")])
        #expect(model.notices.isEmpty)
    }
}
