import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct ProfileTests {
    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-profile-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        model.apply([.me(id: "9@s.whatsapp.net", lid: nil, name: "Komil", about: "Busy")])
        return (model, backend)
    }

    private func profiles(_ backend: PreviewBackend) -> [BridgeCommand] {
        backend.sent.filter { if case .setProfile = $0 { true } else { false } }
    }

    @Test func onlyWhatChangedIsSent() {
        let (model, backend) = model()
        model.saveProfile(name: "Komil", about: "Busy")
        model.saveProfile(name: " Komil ", about: "Here")
        model.saveProfile(name: "", about: "Busy")
        #expect(profiles(backend) == [.setProfile(name: nil, about: "Here")])
    }

    @Test func aboutCanBeClearedAndLongTextIsCut() {
        let (model, backend) = model()
        model.saveProfile(name: String(repeating: "n", count: 40), about: "")
        #expect(profiles(backend) == [.setProfile(name: String(repeating: "n", count: 25), about: "")])
    }

    @Test func aReplacedPictureBumpsItsVersion() {
        let (model, _) = model()
        model.apply([.avatar(id: "9@s.whatsapp.net", full: false, path: "/tmp/me.jpg")])
        let first = model.avatars.version(for: "9@s.whatsapp.net")
        model.apply([.avatar(id: "9@s.whatsapp.net", full: false, path: "/tmp/me.jpg")])
        #expect(model.avatars.version(for: "9@s.whatsapp.net") == first + 1)
    }
}
