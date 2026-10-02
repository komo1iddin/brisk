import Foundation
import ZapFastBridge

/// The seam between call state and the bridge's call center.
/// `LiveCallService` is the real one; previews and tests pass their own.
public protocol CallService: AnyObject {
    /// Delivers call changes on the main actor, and the other side's audio
    /// into `playout` straight from the bridge's thread.
    func connect(playout: PlayoutBuffer, onCall: @escaping @MainActor (CallInfo) -> Void)
    func place(chat: String) -> Bool
    func answer(session: UInt64)
    /// Declines the call if it rings, or ends it.
    func end(session: UInt64)
    func setMuted(_ muted: Bool)
    /// Where microphone frames go, from the audio thread.
    var microphone: @Sendable ([Int16]) -> Void { get }
}

public final class LiveCallService: CallService {
    private let center = CallCenter.shared()

    public init() {}

    public func connect(playout: PlayoutBuffer, onCall: @escaping @MainActor (CallInfo) -> Void) {
        center.setListener(listener: CallRelay(playout: playout, onCall: onCall))
    }

    public func place(chat: String) -> Bool { center.place(chat: chat) }
    public func answer(session: UInt64) { center.answer(session: session) }
    public func end(session: UInt64) { center.end(session: session) }
    public func setMuted(_ muted: Bool) { center.setMuted(muted: muted) }

    public var microphone: @Sendable ([Int16]) -> Void {
        { [center] samples in center.pushMicrophone(samples: samples) }
    }
}

/// Receives the bridge's call callbacks on its threads: changes go to the
/// main queue in order, audio straight into the playout buffer.
nonisolated private final class CallRelay: CallListener, Sendable {
    private let playout: PlayoutBuffer
    private let onCall: @MainActor (CallInfo) -> Void

    init(playout: PlayoutBuffer, onCall: @escaping @MainActor (CallInfo) -> Void) {
        self.playout = playout
        self.onCall = onCall
    }

    func onCall(call: CallInfo) {
        let onCall = self.onCall
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onCall(call) }
        }
    }

    func onPlayout(samples: [Int16]) {
        playout.write(samples)
    }
}

/// A call center that goes nowhere, for previews and tests: it records what
/// it was asked and lets a test play the bridge's part.
public final class PreviewCallService: CallService {
    public enum Request: Equatable {
        case place(String), answer(UInt64), end(UInt64), muted(Bool)
    }

    public private(set) var requests: [Request] = []
    /// What `place` answers.
    public var accepts = true
    private var onCall: (@MainActor (CallInfo) -> Void)?

    public init() {}

    public func connect(playout: PlayoutBuffer, onCall: @escaping @MainActor (CallInfo) -> Void) {
        self.onCall = onCall
    }

    public func place(chat: String) -> Bool {
        requests.append(.place(chat))
        return accepts
    }

    public func answer(session: UInt64) { requests.append(.answer(session)) }
    public func end(session: UInt64) { requests.append(.end(session)) }
    public func setMuted(_ muted: Bool) { requests.append(.muted(muted)) }
    public var microphone: @Sendable ([Int16]) -> Void { { _ in } }

    /// Plays the bridge reporting `call`.
    public func report(_ call: CallInfo) {
        onCall?(call)
    }
}
