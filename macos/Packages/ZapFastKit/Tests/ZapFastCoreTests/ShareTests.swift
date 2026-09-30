import Foundation
import Testing
@testable import ZapFastCore

@MainActor
struct ShareTests {
    private let home = FileManager.default.temporaryDirectory.appending(path: "zapfast-home-\(UUID().uuidString)")

    private func list(files: [String], text: [String], in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "share.json")
        let json = try JSONSerialization.data(withJSONObject: ["files": files, "text": text])
        try json.write(to: url)
        return url
    }

    private func link(_ list: URL) -> URL {
        var components = URLComponents()
        components.scheme = "zapfast-mac"
        components.host = "share"
        components.queryItems = [URLQueryItem(name: "list", value: list.path(percentEncoded: false))]
        return components.url!
    }

    @Test func aListFromTheExtensionBecomesARequestAndIsRemoved() throws {
        let container = home.appending(path: "Library/Containers/com.komoliddin.ZapFastMac.Share/Data/tmp/Shared-1")
        let photo = container.appending(path: "photo.jpg")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try Data([1]).write(to: photo)
        let list = try list(files: [photo.path(percentEncoded: false), "/gone/away.pdf"], text: [" https://example.com ", ""], in: container)

        let request = try #require(ShareRequest.read(link(list), home: home))
        #expect(request.files == [photo])
        #expect(request.text == "https://example.com")
        #expect(!FileManager.default.fileExists(atPath: list.path(percentEncoded: false)))
    }

    @Test func aListFromElsewhereOrAnotherLinkIsIgnored() throws {
        let elsewhere = try list(files: [], text: ["hi"], in: home.appending(path: "Desktop"))
        #expect(ShareRequest.read(link(elsewhere), home: home) == nil)
        #expect(ShareRequest.read(URL(string: "zapfast-mac://other?list=/x")!, home: home) == nil)
        let sneaky = home.appending(path: "Library/Containers/com.komoliddin.ZapFastMac.Share/Data/../../../../Desktop/share.json")
        #expect(ShareRequest.read(link(sneaky), home: home) == nil)
    }

    @Test func deliveringPutsItInTheChosenChatsComposer() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-share-\(UUID().uuidString)")
        let model = AppModel(
            backend: PreviewBackend(), paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        model.composerText["c@s.whatsapp.net"] = "look"
        model.shareRequest = ShareRequest(files: [URL(filePath: "/tmp/a.pdf")], text: "https://example.com")
        model.deliverShare(to: "c@s.whatsapp.net")
        #expect(model.selectedChatID == "c@s.whatsapp.net")
        #expect(model.attachments["c@s.whatsapp.net"]?.count == 1)
        #expect(model.composerText["c@s.whatsapp.net"] == "look\nhttps://example.com")
        #expect(model.shareRequest == nil)
    }
}
