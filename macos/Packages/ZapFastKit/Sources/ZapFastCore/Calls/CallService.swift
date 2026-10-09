import Foundation
import ZapFastBridge

/// Where the bridge's call callbacks go. Changes and history arrive on the
/// main actor; audio, video and keyframe requests straight from the bridge's
/// threads, since they come many times a second.
public struct CallSinks {
    public var playout: PlayoutBuffer
    public var onCall: @MainActor (CallInfo) -> Void
    public var onCallLog: @MainActor (CallLogEntry) -> Void
    public var onVideo: @Sendable (VideoFrameInfo) -> Void
    public var onKeyframeNeeded: @Sendable () -> Void
}

/// The seam between call state and the bridge's call center.
/// `LiveCallService` is the real one; previews and tests pass their own.
public protocol CallService: AnyObject {
    func connect(_ sinks: CallSinks)
    /// A chat's calls, oldest first.
    func history(chat: String) -> [CallLogEntry]
    func place(chat: String, video: Bool) -> Bool
    func answer(session: UInt64, video: Bool)
    /// Declines the call if it rings, or ends it.
    func end(session: UInt64)
    func setMuted(_ muted: Bool)
    func setCamera(_ on: Bool)
    /// Asks the other side for a keyframe, from the decoder's thread.
    var requestKeyframe: @Sendable () -> Void { get }
    /// Where microphone frames go, from the audio thread.
    var microphone: @Sendable ([Int16]) -> Void { get }
    /// Where encoded camera frames go, with their 90 kHz capture times.
    var camera: @Sendable (Data, UInt32) -> Void { get }
}

public final class LiveCallService: CallService {
    private let center: CallCenter

    /// The calls of account `account`.
    public init(account: String) {
        center = CallCenter.forAccount(account: account)
    }

    public func connect(_ sinks: CallSinks) {
        center.setListener(listener: CallRelay(sinks))
    }

    public func history(chat: String) -> [CallLogEntry] { center.history(chat: chat) }
    public func place(chat: String, video: Bool) -> Bool { center.place(chat: chat, video: video) }
    public func answer(session: UInt64, video: Bool) { center.answer(session: session, video: video) }
    public func end(session: UInt64) { center.end(session: session) }
    public func setMuted(_ muted: Bool) { center.setMuted(muted: muted) }
    public func setCamera(_ on: Bool) { center.setCamera(on: on) }

    public var requestKeyframe: @Sendable () -> Void {
        { [center] in center.requestKeyframe() }
    }

    public var microphone: @Sendable ([Int16]) -> Void {
        { [center] samples in center.pushMicrophone(samples: samples) }
    }

    public var camera: @Sendable (Data, UInt32) -> Void {
        { [center] data, timestamp in center.pushVideo(data: data, timestamp: timestamp) }
    }
}

/// Receives the bridge's call callbacks on its threads: changes go to the
/// main queue in order, media straight where it is used.
nonisolated private final class CallRelay: CallListener, @unchecked Sendable {
    private let sinks: CallSinks

    init(_ sinks: CallSinks) {
        self.sinks = sinks
    }

    func onCall(call: CallInfo) {
        let onCall = sinks.onCall
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onCall(call) }
        }
    }

    func onPlayout(samples: [Int16]) {
        sinks.playout.write(samples)
    }

    func onCallLog(entry: CallLogEntry) {
        let onCallLog = sinks.onCallLog
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onCallLog(entry) }
        }
    }

    func onVideo(frame: VideoFrameInfo) {
        sinks.onVideo(frame)
    }

    func onKeyframeNeeded() {
        sinks.onKeyframeNeeded()
    }
}

/// A call center that goes nowhere, for previews and tests: it records what
/// it was asked and lets a test play the bridge's part.
public final class PreviewCallService: CallService {
    public enum Request: Equatable {
        case place(String, video: Bool), answer(UInt64, video: Bool), end(UInt64), muted(Bool), camera(Bool)
    }

    public private(set) var requests: [Request] = []
    /// What `place` answers.
    public var accepts = true
    /// The calls `history` reads.
    public var calls: [CallLogEntry] = []
    private var sinks: CallSinks?

    public init() {}

    public func connect(_ sinks: CallSinks) {
        self.sinks = sinks
    }

    public func history(chat: String) -> [CallLogEntry] {
        calls.filter { $0.chat == chat }
    }

    public func place(chat: String, video: Bool) -> Bool {
        requests.append(.place(chat, video: video))
        return accepts
    }

    public func answer(session: UInt64, video: Bool) { requests.append(.answer(session, video: video)) }
    public func end(session: UInt64) { requests.append(.end(session)) }
    public func setMuted(_ muted: Bool) { requests.append(.muted(muted)) }
    public func setCamera(_ on: Bool) { requests.append(.camera(on)) }
    public var requestKeyframe: @Sendable () -> Void { {} }
    public var microphone: @Sendable ([Int16]) -> Void { { _ in } }
    public var camera: @Sendable (Data, UInt32) -> Void { { _, _ in } }

    /// Plays the bridge reporting `call`.
    public func report(_ call: CallInfo) {
        sinks?.onCall(call)
    }

    /// Plays the bridge filing `entry` in the history.
    public func report(log entry: CallLogEntry) {
        sinks?.onCallLog(entry)
    }
}
