import Foundation
import Observation
import ZapFastBridge

/// The voice calls going now: what the call window shows, the intents it
/// calls, and the sound that goes with each phase (the ring, the ringback,
/// the conversation, the call-waiting beeps). The bridge decides the phases;
/// this follows them.
@Observable
public final class CallStore {
    /// The call, from the first ring to a moment after it ends.
    public private(set) var call: CallInfo?
    /// A second call ringing while `call` goes. Answering it ends `call`:
    /// WhatsApp has no hold.
    public private(set) var waiting: CallInfo?
    /// When both sides of `call` started talking.
    public private(set) var connectedAt: Date?
    /// Each chat's calls, for its timeline.
    public let history: CallHistory

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
        history = CallHistory(read: { [service] chat in service.history(chat: chat) })
        microphoneAllowed = live ? { await VoiceRecorder.microphoneAllowed() } : { true }
        service.connect(
            playout: playout,
            onCall: { [weak self] call in self?.update(call) },
            onCallLog: { [weak self] entry in self?.history.add(entry) }
        )
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

    /// Answers the ringing call.
    public func answer() async {
        guard let call, call.phase == .ringing else { return }
        await answer(call.session)
    }

    /// Ends the call that goes and answers the waiting one.
    public func answerWaiting() async {
        guard let waiting else { return }
        await answer(waiting.session)
    }

    private func answer(_ session: UInt64) async {
        guard await microphoneAllowed() else {
            deniedMicrophone()
            service.end(session: session)
            return
        }
        service.answer(session: session)
    }

    /// Declines a ringing call or ends the one going.
    public func hangUp() {
        guard let call, isBusy else { return }
        service.end(session: call.session)
    }

    public func declineWaiting() {
        guard let waiting else { return }
        service.end(session: waiting.session)
    }

    public func toggleMute() {
        guard let call, isBusy else { return }
        service.setMuted(!call.muted)
    }

    // MARK: From the bridge

    func update(_ new: CallInfo) {
        defer { follow() }
        if new.session == waiting?.session {
            switch new.phase {
            case .ringing: waiting = new
            case .ended: waiting = nil
            case .calling, .connecting, .active:
                // Answered: it takes the panel.
                waiting = nil
                show(new)
            }
            return
        }
        if let call, call.session != new.session, !call.phase.isEnded, new.phase == .ringing {
            waiting = new
            return
        }
        // A late report of a call already replaced changes nothing.
        if let call, call.session > new.session { return }
        show(new)
        guard new.phase.isEnded else { return }
        if let waiting {
            // The call waiting rings on in the panel at once.
            self.waiting = nil
            show(waiting)
            return
        }
        let session = new.session
        let lingering = lingering
        Task { [weak self] in
            try? await Task.sleep(for: lingering)
            guard let self, self.call?.session == session else { return }
            self.call = nil
            self.connectedAt = nil
        }
    }

    private func show(_ new: CallInfo) {
        if call?.session != new.session {
            connectedAt = nil
        }
        if new.phase == .active, connectedAt == nil { connectedAt = .now }
        call = new
    }

    #if DEBUG
    /// Shows `call` as if the bridge had reported it, without sound or the
    /// network, to look at the call window.
    public func debugShow(_ call: CallInfo?, waiting: CallInfo? = nil) {
        self.call = call
        self.waiting = waiting
        connectedAt = call?.phase == .active ? .now.addingTimeInterval(-75) : nil
    }
    #endif

    /// Starts and stops the sound for what rings and goes now.
    private func follow() {
        guard live else { return }
        switch call?.phase {
        case .ringing:
            audio.stop()
            ringer.start()
        case .calling, .connecting, .active:
            ringer.stop()
            if !audio.isRunning {
                playout.reset()
                if !audio.start(playout: playout, send: service.microphone) {
                    onNotice(.error, String(localized: "Could not use the microphone or the speaker for the call."))
                    hangUp()
                    return
                }
            }
            audio.setTone(waiting != nil ? .waiting : call?.phase == .calling ? .ringback : nil)
        case .ended, nil:
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
