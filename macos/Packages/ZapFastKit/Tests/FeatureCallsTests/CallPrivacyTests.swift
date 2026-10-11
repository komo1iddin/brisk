import Testing
import ZapFastBridge
@testable import FeatureCalls

@MainActor
struct CallPrivacyTests {
    private func call(_ phase: CallPhase, camera: Bool, peerVideo: Bool) -> CallInfo {
        CallInfo(
            session: 1, chat: "sample@s.whatsapp.net", incoming: true,
            videoOffered: true, phase: phase, muted: false, camera: camera,
            peerVideo: peerVideo, videoRequested: false, group: false, caller: nil, participants: []
        )
    }

    @Test(arguments: [CallPhase.calling, .connecting, .active, .ringing, .ended(reason: .hungUp)])
    func lockedCallsNeverShowEitherVideo(phase: CallPhase) {
        #expect(!call(phase, camera: true, peerVideo: true).showsVideo(locked: true))
        #expect(!call(phase, camera: true, peerVideo: false).showsVideo(locked: true))
        #expect(!call(phase, camera: false, peerVideo: true).showsVideo(locked: true))
    }

    @Test func anUnlockedActiveCallShowsTheOtherSidesVideo() {
        #expect(call(.active, camera: false, peerVideo: true).showsVideo(locked: false))
    }
}
