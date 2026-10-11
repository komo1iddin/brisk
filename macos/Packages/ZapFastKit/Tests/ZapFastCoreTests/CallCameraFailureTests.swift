import AVFoundation
import Foundation
import Synchronization
import Testing
import ZapFastBridge
@testable import ZapFastCore

nonisolated private final class CameraFlag: Sendable { let configured = Atomic<Bool>(false) }

@MainActor
struct CallCameraFailureTests {
    private func info(_ session: UInt64) -> CallInfo {
        CallInfo(session: session, chat: "fixture", incoming: false, videoOffered: true, phase: .active,
                 muted: false, camera: true, peerVideo: false, videoRequested: false, group: false,
                 caller: nil, participants: [])
    }
    private func wait(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func failedConfigurationTurnsCameraOffAndKeepsVoice() async {
        let service = PreviewCallService()
        let calls = CallStore(service: service, live: false)
        var notices = 0
        calls.onNotice = { _, _ in notices += 1 }
        calls.cameraFactory = { send, failed in
            CallCamera(frameRate: 20, send: send, onFailure: failed, configure: { _ in false })
        }
        service.report(info(1))
        await wait { calls.camera == nil }
        #expect(calls.call?.phase == .active)
        #expect(calls.call?.camera == false)
        #expect(notices == 1)
        #expect(service.requests == [.camera(false)])
        calls.shutdown()
    }

    @Test func interruptionTurnsCameraOffWithoutAutomaticallyRestartingIt() async throws {
        let service = PreviewCallService()
        let calls = CallStore(service: service, live: false)
        let flag = CameraFlag()
        calls.cameraFactory = { send, failed in
            CallCamera(frameRate: 20, send: send, onFailure: failed, configure: { _ in
                flag.configured.store(true, ordering: .releasing); return true
            })
        }
        service.report(info(1))
        let camera = try #require(calls.camera)
        await wait { flag.configured.load(ordering: .acquiring) }
        NotificationCenter.default.post(name: AVCaptureSession.wasInterruptedNotification, object: camera.session)
        await wait { calls.camera == nil }
        #expect(calls.call?.camera == false)
        service.report(info(1))
        #expect(calls.camera == nil)
        #expect(calls.call?.camera == false)
        calls.shutdown()
    }

    @Test func anOldCameraFailureCannotTurnOffItsReplacement() async throws {
        let service = PreviewCallService()
        let calls = CallStore(service: service, live: false)
        let release = DispatchSemaphore(value: 0)
        var made = 0
        calls.cameraFactory = { send, failed in
            made += 1
            let first = made == 1
            return CallCamera(frameRate: 20, send: send, onFailure: failed, configure: { _ in
                if first { _ = release.wait(timeout: .now() + 3); return false }
                return true
            })
        }
        service.report(info(1))
        let old = try #require(calls.camera)
        service.report(info(2))
        let current = try #require(calls.camera)
        release.signal()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(current !== old)
        #expect(calls.camera === current)
        #expect(calls.call?.camera == true)
        #expect(!service.requests.contains(.camera(false)))
        calls.shutdown()
    }

    @Test func stoppedCaptureCannotFeedALaterCallThroughTheSharedHandle() {
        let gate = CallCaptureGate()
        var delivered: [Int] = []
        let encoderOutput = { (frame: Int) in gate.forward { delivered.append(frame) } }
        encoderOutput(1)
        gate.close()
        encoderOutput(2)
        #expect(delivered == [1])
    }

    @Test func lockingStopsRemoteDecoderCallbacksUntilUnlock() async {
        let service = PreviewCallService()
        let calls = CallStore(service: service, live: false)
        service.report(info(1))
        service.report(video: VideoFrameInfo(data: Data(), keyframe: false, orientation: 3))
        await wait { calls.remoteOrientation == 3 }
        #expect(calls.remoteOrientation == 3)
        calls.setLocked(true)
        service.report(video: VideoFrameInfo(data: Data(), keyframe: false, orientation: 1))
        try? await Task.sleep(for: .milliseconds(40))
        #expect(calls.remoteOrientation == 0)
        calls.setLocked(false)
        service.report(video: VideoFrameInfo(data: Data(), keyframe: false, orientation: 1))
        await wait { calls.remoteOrientation == 1 }
        #expect(calls.remoteOrientation == 1)
        calls.shutdown()
    }

}
