import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import Testing
import ZapFastBridge
@testable import ZapFastCore

/// Voice calls: the store follows the bridge's phases and sends the
/// person's intents back; the playout buffer smooths the other side's audio.
@MainActor
struct CallTests {
    private let chat = "998901234567@s.whatsapp.net"

    private func info(
        _ phase: CallPhase, session: UInt64 = 1, incoming: Bool = false, muted: Bool = false, camera: Bool = false
    ) -> CallInfo {
        CallInfo(
            session: session, chat: chat, incoming: incoming, videoOffered: false, phase: phase, muted: muted,
            camera: camera, peerVideo: false, videoRequested: false
        )
    }

    private func store() -> (CallStore, PreviewCallService) {
        let service = PreviewCallService()
        return (CallStore(service: service, live: false), service)
    }

    @Test func placingAsksTheBridge() async {
        let (calls, service) = store()
        await calls.place(chat: chat)
        #expect(service.requests == [.place(chat, video: false)])
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
        #expect(service.requests == [.answer(2, video: false)])
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
        #expect(service.requests == [.answer(2, video: false)])
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

    @Test func aVideoCallAsksForTheCamera() async {
        let (calls, service) = store()
        await calls.place(chat: chat, video: true)
        #expect(service.requests == [.place(chat, video: true)])
    }

    @Test func withoutTheCameraAVideoCallGoesOnWithVoice() async {
        let (calls, service) = store()
        calls.cameraAllowed = { false }
        var notices: [String] = []
        calls.onNotice = { _, text in notices.append(text) }
        await calls.place(chat: chat, video: true)
        #expect(service.requests == [.place(chat, video: false)])
        #expect(notices.count == 1)
    }

    @Test func aVideoOfferCanBeAnsweredWithTheCamera() async {
        let (calls, service) = store()
        service.report(info(.ringing, incoming: true))
        await calls.answer(video: true)
        #expect(service.requests == [.answer(1, video: true)])
    }

    @Test func theCameraTogglesOnlyDuringACall() async {
        let (calls, service) = store()
        service.report(info(.ringing, incoming: true))
        await calls.toggleCamera()
        #expect(service.requests.isEmpty)
        service.report(info(.active, incoming: true))
        await calls.toggleCamera()
        service.report(info(.active, incoming: true, camera: true))
        await calls.toggleCamera()
        #expect(service.requests == [.camera(true), .camera(false)])
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

/// A chat's calls show among its messages: in their place by time, breaking
/// the runs around them, and only as far back as the messages go.
@MainActor
struct CallHistoryTests {
    private let chat = "c@s.whatsapp.net"
    /// Noon on 14 November 2023, UTC.
    private let noon: Int64 = 1_699_963_200

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func message(_ id: String, at time: Int64) -> MessageRecord {
        MessageRecord(
            id: id, chat: chat, sender: "a@s.whatsapp.net", senderName: nil, fromMe: false, timestamp: time,
            content: .text(text: id, preview: nil), status: .none, deliveredAt: nil, readAt: nil, quoted: nil,
            reactions: [], edited: false, mentions: [], forwarded: false, thumbnail: nil, summary: id
        )
    }

    private func call(_ id: String, at time: Int64, outcome: CallOutcome = .missed) -> CallLogEntry {
        CallLogEntry(
            callId: id, chat: chat, fromMe: false, video: false, outcome: outcome, timestamp: time, duration: 0
        )
    }

    private func rows(_ messages: [MessageRecord], _ calls: [CallLogEntry], fromStart: Bool = false) -> [TimelineRow] {
        TimelineRow.build(messages, calls: calls, fromStart: fromStart, calendar: calendar)
    }

    @Test func aCallSitsBetweenTheMessagesOfItsTime() {
        let built = rows([message("a", at: noon), message("b", at: noon + 120)], [call("x", at: noon + 60)])
        #expect(built.map(\.id) == ["day-1699920000", "a", "call-x", "b"])
    }

    @Test func aCallBreaksTheRunAroundIt() {
        let built = rows([message("a", at: noon), message("b", at: noon + 120)], [call("x", at: noon + 60)])
        let runs = built.compactMap { row -> (Bool, Bool)? in
            if case let .message(_, starts, ends) = row { (starts, ends) } else { nil }
        }
        #expect(runs.map(\.0) == [true, true])
        #expect(runs.map(\.1) == [true, true])
    }

    @Test func aCallOnItsOwnDayGetsTheDay() {
        let built = rows([message("a", at: noon)], [call("x", at: noon + 86_400)])
        #expect(built.map(\.id) == ["day-1699920000", "a", "day-1700006400", "call-x"])
    }

    @Test func olderCallsWaitForTheirPage() {
        let old = call("x", at: noon - 3600)
        #expect(!rows([message("a", at: noon)], [old]).contains { $0.id == "call-x" })
        #expect(rows([message("a", at: noon)], [old], fromStart: true).map(\.id).dropFirst().first == "call-x")
    }

    @Test func aChatOfOnlyCallsShowsThem() {
        #expect(rows([], [call("x", at: noon)]).map(\.id) == ["day-1699920000", "call-x"])
    }

    @Test func withoutCallsTheRowsAreAsBefore() {
        let messages = [message("a", at: noon), message("b", at: noon + 10)]
        #expect(rows(messages, []) == TimelineRow.build(messages, calendar: calendar))
    }

    @Test func historyReadsOnceAndFollowsTheBridge() {
        let service = PreviewCallService()
        service.calls = [call("x", at: noon)]
        let calls = CallStore(service: service, live: false)
        #expect(calls.history.calls(in: chat).map(\.callId) == ["x"])
        service.calls = []
        #expect(calls.history.calls(in: chat).count == 1, "read once, then kept")
        service.report(log: call("w", at: noon - 10))
        service.report(log: call("x", at: noon, outcome: .connected))
        #expect(calls.history.calls(in: chat).map(\.callId) == ["w", "x"])
        #expect(calls.history.calls(in: chat).last?.outcome == .connected)
    }

    @Test func aCallReadsAsThePhoneShowsIt() {
        #expect(CallText.title(call("x", at: noon)).hasPrefix("Missed voice call · "))
        var talked = call("y", at: noon, outcome: .connected)
        talked.duration = 125
        #expect(CallText.title(talked).hasPrefix("Voice call · 2 min"))
        talked.duration = 40
        #expect(CallText.title(talked).hasPrefix("Voice call · 40 sec"))
    }
}


/// WhatsApp's video is Annex-B; VideoToolbox's is AVCC. The encoder's units
/// carry their parameter sets before each keyframe, as WhatsApp's do.
struct VideoCodingTests {
    private let sps = Data([0x67, 0x42, 0xE0, 0x1F, 0x8C])
    private let pps = Data([0x68, 0xCE, 0x3C, 0x80])
    private let idr = Data([0x65, 0x88, 0x84, 0x00, 0x21])

    @Test func annexBSplitsOnEitherStartCode() {
        var data = Data([0, 0, 0, 1]) + sps
        data += Data([0, 0, 1]) + pps
        data += Data([0, 0, 0, 1]) + idr
        #expect(H264.units(annexB: data) == [sps, pps, idr])
        #expect(H264.type(of: idr) == H264.Unit.idr.rawValue)
    }

    @Test func avccAndAnnexBCarryTheSameUnits() {
        let units = [sps, pps, idr]
        #expect(H264.units(avcc: H264.avcc(units)) == units)
        #expect(H264.units(annexB: H264.annexB(units)) == units)
    }

    @Test func aTruncatedAVCCStopsAtTheBrokenUnit() {
        var data = H264.avcc([sps, pps])
        data += Data([0, 0, 0, 40, 1, 2])
        #expect(H264.units(avcc: data) == [sps, pps])
    }

    @Test func theEncoderMakesAKeyframeWithItsParameterSetsFirst() throws {
        let units = Mutex<[Data]>([])
        let done = DispatchSemaphore(value: 0)
        let encoder = try #require(VideoEncoder(width: 320, height: 240, frameRate: 20) { data, _ in
            units.withLock { $0 = H264.units(annexB: data) }
            done.signal()
        })
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        let image = try #require(buffer)
        encoder.encode(image, at: CMTime(value: 1, timescale: 20))
        #expect(done.wait(timeout: .now() + 5) == .success)
        let types = units.withLock { $0.map(H264.type(of:)) }
        #expect(types.prefix(2) == [H264.Unit.sps.rawValue, H264.Unit.pps.rawValue])
        #expect(types.contains(H264.Unit.idr.rawValue))
        // Constrained Baseline, as WhatsApp sends: profile 66, constraint flag 1.
        let profile = units.withLock { $0.first.map { Array($0.prefix(3)) } }
        #expect(profile?[1] == 66)
        #expect((profile?[2] ?? 0) & 0x40 != 0)
    }
}
