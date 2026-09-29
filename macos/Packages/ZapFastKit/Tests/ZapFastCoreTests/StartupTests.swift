import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

/// A backend whose first start fails the way a missing folder did.
private final class FlakyBackend: Backend {
    var starts = 0

    func start(paths: AppPaths, verbose: Bool, deliver: @escaping @MainActor ([BridgeEvent]) -> Void) throws {
        starts += 1
        if starts == 1 { throw BridgeError.Storage(message: "No such file or directory") }
    }

    func send(_ command: BridgeCommand) {}
    func shutdown() {}
}

@MainActor
struct StartupTests {
    private func model(_ backend: Backend) -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-startup-\(UUID().uuidString)")
        return AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
    }

    @Test func tryAgainRetriesAStartThatFailed() {
        let backend = FlakyBackend()
        let model = model(backend)

        model.start()
        guard case .failed = model.session.link else {
            Issue.record("expected a failed link, got \(model.session.link)")
            return
        }

        model.reconnect()
        #expect(backend.starts == 2)
        #expect(model.session.link == .starting)
    }

    @Test func anotherInstanceSaysSoPlainly() {
        final class Locked: Backend {
            func start(paths: AppPaths, verbose: Bool, deliver: @escaping @MainActor ([BridgeEvent]) -> Void) throws {
                throw BridgeError.AnotherInstance
            }
            func send(_ command: BridgeCommand) {}
            func shutdown() {}
        }
        let model = model(Locked())
        model.start()
        #expect(model.session.link == .failed(message: "ZapFast is already running."))
    }
}
