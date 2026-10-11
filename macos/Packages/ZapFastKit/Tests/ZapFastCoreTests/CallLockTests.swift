import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct CallLockTests {
    private func info(_ phase: CallPhase, session: UInt64 = 1, camera: Bool = false) -> CallInfo {
        CallInfo(
            session: session, chat: "sample@s.whatsapp.net", incoming: true,
            videoOffered: true, phase: phase, muted: false, camera: camera,
            peerVideo: true, videoRequested: false, group: false, caller: nil, participants: []
        )
    }

    @Test func lockingAnActiveCallTurnsOffTheCameraWithoutEndingAudio() {
        let service = PreviewCallService()
        let calls = CallStore(service: service, live: false)
        service.report(info(.active, camera: true))
        calls.setLocked(true)
        calls.setLocked(true)
        #expect(calls.isLocked)
        #expect(calls.call?.camera == false)
        #expect(calls.call?.phase == .active)
        #expect(calls.camera == nil)
        #expect(service.requests == [.camera(false)])
    }

    @Test func unlockingDoesNotResumeTheCameraFromALateBridgeReport() async {
        let service = PreviewCallService()
        let calls = CallStore(service: service, live: false)
        service.report(info(.active, camera: true))
        calls.setLocked(true)
        calls.setLocked(false)
        service.report(info(.active, camera: true))
        #expect(calls.call?.camera == false)
        #expect(service.requests.allSatisfy { $0 == .camera(false) })
        await calls.toggleCamera()
        #expect(service.requests.last == .camera(true))
        service.report(info(.active, camera: true))
        #expect(calls.call?.camera == true)
    }

    @Test func aVideoOfferWhileLockedIsAnsweredWithVoiceWithoutCameraPermission() async {
        let service = PreviewCallService()
        let calls = CallStore(service: service, live: false)
        var cameraRequests = 0
        calls.cameraAllowed = { cameraRequests += 1; return true }
        calls.setLocked(true)
        service.report(info(.ringing))
        await calls.answer(video: true)
        #expect(cameraRequests == 0)
        #expect(service.requests == [.answer(1, video: false)])
    }

    @Test func lockingWhileCameraPermissionIsPendingPreventsCapture() async {
        let service = PreviewCallService()
        let calls = CallStore(service: service, live: false)
        service.report(info(.active))
        calls.cameraAllowed = { calls.setLocked(true); return true }
        await calls.toggleCamera()
        #expect(calls.isLocked)
        #expect(!service.requests.contains(.camera(true)))
        #expect(calls.camera == nil)
    }

    @Test func theAppLockReachesItsCallStore() {
        let service = PreviewCallService()
        let preferences = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let model = AppModel(backend: PreviewBackend(), preferences: preferences, calls: service)
        service.report(info(.active, camera: true))
        preferences.appLockVerifier = "synthetic-verifier"
        model.appLock.lock()
        #expect(model.calls.isLocked)
        #expect(model.calls.call?.camera == false)
        #expect(service.requests == [.camera(false)])
    }

    @Test func aNewModelHonorsAnAlreadyLockedScreen() {
        let preferences = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        preferences.appLockVerifier = "synthetic-verifier"
        let model = AppModel(backend: PreviewBackend(), preferences: preferences)
        #expect(model.appLock.isLocked)
        #expect(model.calls.isLocked)
    }
}
