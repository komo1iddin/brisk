import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

/// Voice calls: the store follows the bridge's phases and sends the
/// person's intents back; the playout buffer smooths the other side's audio.
@MainActor
struct CallTests {
    private let chat = "998901234567@s.whatsapp.net"

    private func info(_ phase: CallPhase, session: UInt64 = 1, incoming: Bool = false, muted: Bool = false) -> CallInfo {
        CallInfo(session: session, chat: chat, incoming: incoming, videoOffered: false, phase: phase, muted: muted)
    }

    private func store() -> (CallStore, PreviewCallService) {
        let service = PreviewCallService()
        return (CallStore(service: service, live: false), service)
    }

    @Test func placingAsksTheBridge() async {
        let (calls, service) = store()
        await calls.place(chat: chat)
        #expect(service.requests == [.place(chat)])
    }

    @Test func aRefusedCallSaysSo() async {
        let (calls, service) = store()
        service.accepts = false
        var notices: [String] = []
        calls.onNotice = { _, text in notices.append(text) }
        await calls.place(chat: chat)
        #expect(notices.count == 1)
    }

    @Test func noCallStartsWithoutTheMicrophone() async {
        let (calls, service) = store()
        calls.microphoneAllowed = { false }
        var notices: [String] = []
        calls.onNotice = { _, text in notices.append(text) }
        await calls.place(chat: chat)
        #expect(service.requests.isEmpty)
        #expect(notices.count == 1)
    }

    @Test func aRingingCallDeclinedForWantOfAMicrophoneIsHungUp() async {
        let (calls, service) = store()
        calls.microphoneAllowed = { false }
        service.report(info(.ringing, incoming: true))
        await calls.answer()
        #expect(service.requests == [.end(1)])
    }

    @Test func nothingNewStartsWhileACallGoes() async {
        let (calls, service) = store()
        service.report(info(.active))
        #expect(calls.isBusy)
        await calls.place(chat: "other@s.whatsapp.net")
        #expect(service.requests.isEmpty)
    }

    @Test func answeringOnlyAnswersARingingCall() async {
        let (calls, service) = store()
        service.report(info(.calling))
        await calls.answer()
        // Ringing beside a call, it waits: only `answerWaiting` takes it.
        service.report(info(.ringing, session: 2, incoming: true))
        await calls.answer()
        #expect(service.requests.isEmpty)
        service.report(info(.ended(reason: .hungUp)))
        await calls.answer()
        #expect(service.requests == [.answer(2)])
    }

    @Test func theTimerStartsWhenBothSidesTalk() {
        let (calls, service) = store()
        service.report(info(.calling))
        #expect(calls.connectedAt == nil)
        service.report(info(.active))
        let started = calls.connectedAt
        #expect(started != nil)
        service.report(info(.active, muted: true))
        #expect(calls.connectedAt == started)
    }

    @Test func muteFlipsWhatTheBridgeReported() {
        let (calls, service) = store()
        service.report(info(.active, muted: false))
        calls.toggleMute()
        service.report(info(.active, muted: true))
        calls.toggleMute()
        #expect(service.requests == [.muted(true), .muted(false)])
    }

    @Test func hangingUpWhenNothingGoesDoesNothing() {
        let (calls, service) = store()
        calls.hangUp()
        service.report(info(.ended(reason: .peerHungUp)))
        calls.hangUp()
        #expect(service.requests.isEmpty)
    }

    @Test func aLateReportOfAnEarlierCallIsIgnored() {
        let (calls, service) = store()
        service.report(info(.ringing, session: 2, incoming: true))
        service.report(info(.ended(reason: .hungUp), session: 1))
        #expect(calls.call?.session == 2)
        #expect(calls.call?.phase == .ringing)
    }

    @Test func aSecondCallRingsBesideTheFirst() {
        let (calls, service) = store()
        service.report(info(.active))
        service.report(info(.ringing, session: 2, incoming: true))
        #expect(calls.call?.session == 1)
        #expect(calls.waiting?.session == 2)
        calls.declineWaiting()
        #expect(service.requests == [.end(2)])
        service.report(info(.ended(reason: .declined), session: 2, incoming: true))
        #expect(calls.waiting == nil)
        #expect(calls.call?.phase == .active)
    }

    @Test func answeringTheWaitingCallMovesItIntoThePanel() async {
        let (calls, service) = store()
        service.report(info(.active))
        let first = calls.connectedAt
        service.report(info(.ringing, session: 2, incoming: true))
        await calls.answerWaiting()
        #expect(service.requests == [.answer(2)])
        // The bridge ends the first call, then answers the second.
        service.report(info(.ended(reason: .hungUp)))
        #expect(calls.call?.session == 2)
        #expect(calls.call?.phase == .ringing)
        #expect(calls.waiting == nil)
        service.report(info(.connecting, session: 2, incoming: true))
        service.report(info(.active, session: 2, incoming: true))
        #expect(calls.call?.session == 2)
        #expect(calls.connectedAt != nil && calls.connectedAt != first)
    }

    @Test func whenTheFirstCallEndsTheWaitingOneRingsOn() {
        let (calls, service) = store()
        service.report(info(.active))
        service.report(info(.ringing, session: 2, incoming: true))
        service.report(info(.ended(reason: .peerHungUp)))
        #expect(calls.call?.session == 2)
        #expect(calls.call?.phase == .ringing)
        #expect(calls.connectedAt == nil)
        // A late report of the first call does not take the panel back.
        service.report(info(.ended(reason: .peerHungUp)))
        #expect(calls.call?.session == 2)
    }

    @Test func aWaitingCallTheCallerGaveUpOnLeaves() {
        let (calls, service) = store()
        service.report(info(.active))
        service.report(info(.ringing, session: 2, incoming: true))
        service.report(info(.ended(reason: .missed), session: 2, incoming: true))
        #expect(calls.waiting == nil)
        #expect(calls.call?.session == 1)
    }

    @Test func anEndedCallStaysAMomentWithItsReason() async throws {
        let (calls, service) = store()
        calls.lingering = .milliseconds(50)
        service.report(info(.active))
        service.report(info(.ended(reason: .peerHungUp)))
        #expect(calls.call?.phase == .ended(reason: .peerHungUp))
        #expect(!calls.isBusy)
        // A busy machine runs the main actor late; wait up to five seconds.
        for _ in 0 ..< 100 where calls.call != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(calls.call == nil)
        #expect(calls.connectedAt == nil)
    }
}

/// The other side's audio waits for two frames before playing, plays them
/// in order, and drops the oldest when too much has queued.
struct PlayoutBufferTests {
    private func read(_ buffer: PlayoutBuffer, _ frames: Int) -> [Float] {
        var out = [Float](repeating: 9, count: frames)
        out.withUnsafeMutableBufferPointer { buffer.read(into: $0.baseAddress!, frames: frames) }
        return out
    }

    @Test func itWaitsForEnoughAudioBeforePlaying() {
        let buffer = PlayoutBuffer()
        buffer.write([Int16](repeating: 1000, count: PlayoutBuffer.prime - 1))
        #expect(read(buffer, 10).allSatisfy { $0 == 0 })
        #expect(!buffer.isPlaying)
        buffer.write([1000])
        #expect(read(buffer, 10).allSatisfy { $0 > 0 })
        #expect(buffer.isPlaying)
    }

    @Test func itPlaysInOrderAndFillsAGapWithSilence() {
        let buffer = PlayoutBuffer()
        let samples = (0 ..< PlayoutBuffer.prime).map { Int16($0) }
        buffer.write(samples)
        let first = read(buffer, 4)
        #expect(first == [0, 1, 2, 3].map { Float($0) / 32768 })
        let rest = read(buffer, PlayoutBuffer.prime)
        #expect(rest.suffix(4).allSatisfy { $0 == 0 })
        #expect(!buffer.isPlaying, "running dry waits for audio again")
    }

    @Test func tooMuchQueuedDropsTheOldest() {
        let buffer = PlayoutBuffer()
        buffer.write([Int16](repeating: 1, count: PlayoutBuffer.limit))
        buffer.write([Int16](repeating: 2, count: 960))
        #expect(buffer.queued == PlayoutBuffer.limit)
        let all = read(buffer, PlayoutBuffer.limit)
        #expect(all.suffix(960).allSatisfy { $0 == Float(2) / 32768 })
        #expect(all.prefix(PlayoutBuffer.limit - 960).allSatisfy { $0 == Float(1) / 32768 })
    }
}

/// The sounds are drawn, not loaded: each is one loop, quiet enough, and
/// silent between its bursts.
struct CallToneTests {
    @Test func theRingIsOneQuietLoop() throws {
        let ring = try #require(CallTones.ring())
        #expect(Double(ring.frameLength) == 3 * CallTones.sampleRate)
        let samples = UnsafeBufferPointer(start: ring.floatChannelData![0], count: Int(ring.frameLength))
        #expect(samples.allSatisfy { abs($0) <= 0.25 })
        #expect(samples.last == 0)
    }

    @Test func theRingbackIsQuieterStill() throws {
        let ringback = try #require(CallTones.ringback())
        let samples = UnsafeBufferPointer(start: ringback.floatChannelData![0], count: Int(ringback.frameLength))
        #expect(samples.allSatisfy { abs($0) <= 0.13 })
        #expect(samples[Int(2 * CallTones.sampleRate)] == 0)
    }
}
