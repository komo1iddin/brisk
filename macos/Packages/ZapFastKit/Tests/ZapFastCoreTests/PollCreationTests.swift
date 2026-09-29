import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct PollCreationTests {
    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-pollnew-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        model.apply([.link(state: .connected)])
        return (model, backend)
    }

    private let good = PollDraftInfo(question: "Lunch?", options: ["Rice", "Soup"], multiple: true)

    @Test func onlyAValidDraftGoesOutAndOnlyOnceAtATime() {
        let (model, backend) = model()
        model.createPoll(PollDraftInfo(question: "Lunch?", options: ["Rice"], multiple: true), in: "g@g.us")
        model.createPoll(good, in: "g@g.us")
        model.createPoll(good, in: "g@g.us")
        #expect(backend.sent.filter { if case .createPoll = $0 { true } else { false } }
            == [.createPoll(chat: "g@g.us", draft: good)])
    }

    @Test func aSentPollClosesTheSheetAndAFailureKeepsIt() {
        let (model, _) = model()
        model.pollComposerChat = "g@g.us"
        model.createPoll(good, in: "g@g.us")
        model.apply([.pollCreated(chat: "g@g.us", error: "Could not send")])
        #expect(model.pollComposerChat == "g@g.us")
        #expect(!model.pollCreating)

        model.createPoll(good, in: "g@g.us")
        model.apply([.pollCreated(chat: "g@g.us", error: nil)])
        #expect(model.pollComposerChat == nil)
    }
}
