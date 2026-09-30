import Foundation
import Testing
@testable import ZapFastCore

@MainActor
struct FilesAndNetworkTests {
    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-files-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        return (model, backend)
    }

    @Test func downloadsGoWhereChosenOrBackToTheCache() {
        let (model, backend) = model()
        #expect(model.downloadFolderInUse.lastPathComponent == "media")
        model.setDownloadFolder(URL(filePath: "/Users/me/Downloads/WhatsApp"))
        #expect(backend.sent.last == .setDownloadFolder(path: "/Users/me/Downloads/WhatsApp"))
        #expect(model.downloadFolderInUse.path(percentEncoded: false) == "/Users/me/Downloads/WhatsApp")
        let count = backend.sent.count
        model.setDownloadFolder(URL(filePath: "/Users/me/Downloads/WhatsApp"))
        #expect(backend.sent.count == count, "unchanged, nothing sent")
        model.setDownloadFolder(nil)
        #expect(backend.sent.last == .setDownloadFolder(path: nil))
    }

    @Test func aProxyIsCheckedBeforeItIsUsed() {
        let (model, backend) = model()
        #expect(model.setProxy("ftp://127.0.0.1:21") != nil)
        #expect(model.preferences.proxy.isEmpty)
        #expect(backend.sent.isEmpty)

        #expect(model.setProxy(" socks5h://127.0.0.1:9050 ") == nil)
        #expect(model.preferences.proxy == "socks5h://127.0.0.1:9050")
        #expect(backend.sent.last == .setProxy(proxy: "socks5h://127.0.0.1:9050"))

        #expect(model.setProxy("") == nil)
        #expect(backend.sent.last == .setProxy(proxy: ""))
    }

    @Test func zapFastStaysInTheMenuBarAndRunningByDefault() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.menuBarIcon && preferences.keepRunning)
        preferences.keepRunning = false
        preferences.menuBarIcon = false
        let again = Preferences(defaults: defaults)
        #expect(!again.keepRunning && !again.menuBarIcon)
    }
}
