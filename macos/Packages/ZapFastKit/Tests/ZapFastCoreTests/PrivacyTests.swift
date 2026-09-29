import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct PrivacyTests {
    private func model(connected: Bool = true) -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-privacy-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        if connected { model.apply([.link(state: .connected)]) }
        return (model, backend)
    }

    private let fetched: [PrivacyValueInfo] = [
        PrivacyValueInfo(kind: .lastSeen, choice: .contacts),
        PrivacyValueInfo(kind: .profile, choice: .except),
        PrivacyValueInfo(kind: .readReceipts, choice: .everyone),
    ]

    @Test func nothingIsWrittenBeforeThePhonesValuesArrive() {
        let (model, backend) = model()
        model.refreshPrivacy()
        #expect(backend.sent.last == .fetchAccountPrivacy)
        model.setPrivacy(.lastSeen, to: .nobody)
        #expect(backend.sent.last == .fetchAccountPrivacy)
        #expect(!model.privacy.isEditable)
    }

    @Test func aWriteShowsAtOnceAndARefusalRestoresIt() {
        let (model, backend) = model()
        model.apply([.accountPrivacy(values: fetched, failed: false)])
        #expect(model.privacy.choice(.lastSeen) == .contacts)

        model.setPrivacy(.lastSeen, to: .nobody)
        #expect(backend.sent.last == .setAccountPrivacy(kind: .lastSeen, choice: .nobody))
        #expect(model.privacy.choice(.lastSeen) == .nobody)
        #expect(model.privacy.isPending(.lastSeen))

        model.apply([.accountPrivacyFailed(kind: .lastSeen)])
        #expect(model.privacy.choice(.lastSeen) == .contacts)
        #expect(!model.privacy.isPending(.lastSeen))
    }

    @Test func aHeldExceptListIsShownButNotOffered() {
        let (model, _) = model()
        model.apply([.accountPrivacy(values: fetched, failed: false)])
        #expect(model.privacy.choices(.profile) == [.everyone, .contacts, .nobody, .except])
        #expect(model.privacy.choices(.lastSeen) == [.everyone, .contacts, .nobody])
    }

    @Test func accountReadReceiptsWinOverTheLocalSwitch() {
        let (model, _) = model()
        model.apply([.accountPrivacy(values: fetched, failed: false)])
        #expect(!model.session.receiptsDisabled)
        model.setPrivacy(.readReceipts, to: .nobody)
        model.apply([.accountPrivacySaved(kind: .readReceipts)])
        #expect(model.session.receiptsDisabled)
    }

    @Test func offlineNothingIsAsked() {
        let (model, backend) = model(connected: false)
        model.refreshPrivacy()
        #expect(backend.sent.isEmpty)
    }
}
