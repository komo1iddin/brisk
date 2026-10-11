import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct CallMediaOwnershipTests {
    private func info(_ phase: CallPhase, session: UInt64 = 1) -> CallInfo {
        CallInfo(session: session, chat: "fixture", incoming: true, videoOffered: false, phase: phase,
                 muted: false, camera: false, peerVideo: false, videoRequested: false, group: false,
                 caller: nil, participants: [])
    }

    @Test func accountsCannotPlaceOrAnswerWhileAnotherOwnsMedia() async {
        let media = CallMediaCoordinator()
        let a = PreviewCallService(), b = PreviewCallService()
        let first = CallStore(service: a, live: false, media: media)
        let second = CallStore(service: b, live: false, media: media)
        a.report(info(.active))
        b.report(info(.ringing))
        await second.answer()
        #expect(b.requests.isEmpty)
        #expect(second.call?.phase == .ringing)
        a.report(info(.ended(reason: .hungUp)))
        await second.answer()
        #expect(b.requests == [.answer(1, video: false)])
        // A duplicate terminal report cannot release B's ownership.
        a.report(info(.ended(reason: .hungUp)))
        await first.place(chat: "other")
        #expect(a.requests.isEmpty)
        second.shutdown()
        await first.place(chat: "other")
        #expect(a.requests == [.place("other", video: false)])
        first.shutdown()
    }

    @Test func pendingOutgoingCallsReserveMediaAndFailuresReleaseIt() async {
        let media = CallMediaCoordinator()
        let a = PreviewCallService(), b = PreviewCallService()
        let first = CallStore(service: a, live: false, media: media)
        let second = CallStore(service: b, live: false, media: media)
        await first.place(chat: "fixture")
        await first.place(chat: "duplicate")
        await second.place(chat: "other")
        #expect(a.requests.count == 1)
        #expect(b.requests.isEmpty)
        first.reset()
        b.accepts = false
        await second.place(chat: "other")
        b.accepts = true
        await first.place(chat: "again")
        #expect(a.requests.last == .place("again", video: false))
        first.shutdown(); second.shutdown()
    }

    @Test func aLatePermissionResultCannotAnswerAnEndedOrRemovedCall() async {
        let service = PreviewCallService()
        let calls = CallStore(service: service, live: false)
        var permission: CheckedContinuation<Bool, Never>?
        calls.microphoneAllowed = { await withCheckedContinuation { permission = $0 } }
        service.report(info(.ringing))
        let answering = Task { await calls.answer() }
        while permission == nil { await Task.yield() }
        service.report(info(.ended(reason: .missed)))
        permission?.resume(returning: true)
        await answering.value
        #expect(service.requests.isEmpty)
        service.report(info(.ringing, session: 2))
        permission = nil
        let removed = Task { await calls.answer() }
        while permission == nil { await Task.yield() }
        calls.reset()
        permission?.resume(returning: true)
        await removed.value
        service.report(info(.active, session: 2))
        #expect(calls.call == nil)
        #expect(service.requests == [.end(2)])
        calls.shutdown()
    }

    @Test func removalRetiresAPlacedCallWhoseCallbackHasNotArrived() async {
        let service = PreviewCallService()
        let calls = CallStore(service: service, live: false)
        await calls.place(chat: "fixture")
        service.currentCalls = [info(.calling)]
        calls.reset()
        #expect(service.requests == [.place("fixture", video: false), .end(1)])
        service.report(info(.active))
        #expect(calls.call == nil)
        calls.shutdown()
    }

    @Test func aFailedAudioDeviceChangeReportsTheFailureAndEndsItsOwnCall() {
        let service = PreviewCallService()
        let calls = CallStore(service: service, live: false)
        var notices = 0
        calls.onNotice = { _, _ in notices += 1 }
        service.report(info(.active, session: 4))
        calls.audioFailed()
        #expect(service.requests == [.end(4)])
        #expect(notices == 1)
        service.report(info(.ended(reason: .hungUp), session: 4))
        calls.audioFailed()
        #expect(service.requests == [.end(4)])
        calls.shutdown()
    }
}
