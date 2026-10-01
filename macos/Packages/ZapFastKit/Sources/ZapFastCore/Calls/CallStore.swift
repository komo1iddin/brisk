import Foundation
import Observation
import ZapFastBridge

/// The voice call going now: what the call window shows, the intents it
/// calls, and the sound that goes with each phase (the ring, the ringback,
/// the conversation). The bridge decides the phases; this follows them.
@Observable
public final class CallStore {
    /// The call, from the first ring to a moment after it ends.
    public private(set) var call: CallInfo?
    /// When both sides started talking.
    public private(set) var connectedAt: Date?

    /// Shows a short message in the window's notice banner.
    @ObservationIgnored public var onNotice: (Notice.Kind, String) -> Void = { _, _ in }
    /// Asked whether the microphone may be used, asking the person if needed.
    @ObservationIgnored var microphoneAllowed: () async -> Bool

    @ObservationIgnored private let service: CallService
    /// No hardware is touched without it: previews and tests run silent.
    @ObservationIgnored private let live: Bool
    @ObservationIgnored private let playout = PlayoutBuffer()
    @ObservationIgnored private let audio = CallAudio()
    @ObservationIgnored private let ringer = Ringer()
    /// How long an ended call stays on screen with its reason.
    @ObservationIgnored var lingering: Duration = .seconds(2)

    public init(service: CallService, live: Bool) {
        self.service = service
        self.live = live
        microphoneAllowed = live ? { await VoiceRecorder.microphoneAllowed() } : { true }
        service.connect(playout: playout) { [weak self] call in self?.update(call) }
    }

    /// A call is ringing or going; a new one cannot start.
    public var isBusy: Bool {
        guard let call else { return false }
        return !call.phase.isEnded
    }

    // MARK: Intents

    /// Calls a person's chat.
    public func place(chat: String) async {
        guard !isBusy else { return }
        guard await microphoneAllowed() else { return deniedMicrophone() }
        if !service.place(chat: chat) {
            onNotice(.error, String(localized: "Could not start the call. Check the connection and try again."))
        }
    }

    public func answer() async {
        guard call?.phase == .ringing else { return }
        guard await microphoneAllowed() else {
            deniedMicrophone()
            service.hangUp()
            return
        }
        service.answer()
    }

    /// Declines a ringing call or ends the one going.
    public func hangUp() {
        guard isBusy else { return }
        service.hangUp()
    }

    public func toggleMute() {
        guard let call, isBusy else { return }
        service.setMuted(!call.muted)
    }

    // MARK: From the bridge

    func update(_ new: CallInfo) {
        // A late report of a call already replaced changes nothing.
        if let call, call.session > new.session { return }
        if new.phase == .active, call?.phase != .active { connectedAt = .now }
        call = new
        follow(new.phase)
        if new.phase.isEnded {
            let session = new.session
            let lingering = lingering
            Task { [weak self] in
                try? await Task.sleep(for: lingering)
                guard let self, self.call?.session == session else { return }
                self.call = nil
                self.connectedAt = nil
            }
        }
    }

    #if DEBUG
    /// Shows `call` as if the bridge had reported it, without sound or the
    /// network, to look at the call window.
    public func debugShow(_ call: CallInfo?) {
        self.call = call
        connectedAt = call?.phase == .active ? .now.addingTimeInterval(-75) : nil
    }
    #endif

    /// Starts and stops the sound for `phase`.
    private func follow(_ phase: CallPhase) {
        guard live else { return }
        switch phase {
        case .ringing:
            ringer.start()
        case .calling, .connecting, .active:
            ringer.stop()
            if !audio.isRunning {
                playout.reset()
                if !audio.start(playout: playout, send: service.microphone) {
                    onNotice(.error, String(localized: "Could not use the microphone or the speaker for the call."))
                    service.hangUp()
                    return
                }
            }
            audio.setRingback(phase == .calling)
        case .ended:
            ringer.stop()
            audio.stop()
        }
    }

    private func deniedMicrophone() {
        onNotice(.error, String(localized: "ZapFast needs the microphone for calls. Allow it in System Settings › Privacy & Security › Microphone."))
    }
}

extension CallPhase {
    public var isEnded: Bool {
        if case .ended = self { true } else { false }
    }
}
