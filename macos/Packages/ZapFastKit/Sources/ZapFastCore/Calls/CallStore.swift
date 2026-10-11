import Foundation
import Observation
import ZapFastBridge

/// The calls going now: what the call window shows, the intents it calls,
/// and the sound and picture that go with each phase (the ring, the
/// ringback, the conversation, the call-waiting beeps, the cameras). The
/// bridge decides the phases; this follows them.
@Observable
public final class CallStore {
    /// The call, from the first ring to a moment after it ends.
    public private(set) var call: CallInfo?
    /// A second call ringing while `call` goes. Answering it ends `call`:
    /// WhatsApp has no hold.
    public private(set) var waiting: CallInfo?
    /// When both sides of `call` started talking.
    public private(set) var connectedAt: Date?
    /// When `call` ended, while it lingers.
    public private(set) var endedAt: Date?
    /// Each chat's calls, for its timeline.
    public let history: CallHistory
    /// The other side's video, for the call window to show.
    public let remoteVideo: VideoRenderer
    /// Our camera, while it is on: the window shows its preview.
    public private(set) var camera: CallCamera?
    /// The other side's picture's rotation, in quarter turns clockwise.
    public private(set) var remoteOrientation: UInt8 = 0
    /// The shared app lock also hides the call's pictures and stops our camera.
    public private(set) var isLocked = false

    /// Shows a short message in the window's notice banner.
    @ObservationIgnored public var onNotice: (Notice.Kind, String) -> Void = { _, _ in }
    /// Asked whether the microphone may be used, asking the person if needed.
    @ObservationIgnored var microphoneAllowed: () async -> Bool
    /// The same for the camera.
    @ObservationIgnored var cameraAllowed: () async -> Bool

    @ObservationIgnored private let service: CallService
    /// No hardware is touched without it: previews and tests run silent.
    @ObservationIgnored private let live: Bool
    @ObservationIgnored private let playout = PlayoutBuffer()
    @ObservationIgnored private let audio = CallAudio()
    @ObservationIgnored private let ringer = Ringer()
    /// How long an ended call stays on screen with its reason.
    @ObservationIgnored var lingering: Duration = .seconds(2)
    /// Locking requires an explicit camera action before capture can resume.
    @ObservationIgnored private var cameraPermitted = true

    public init(service: CallService, live: Bool) {
        self.service = service
        self.live = live
        history = CallHistory(read: { [service] chat in await service.history(chat: chat) })
        microphoneAllowed = live ? { await VoiceRecorder.microphoneAllowed() } : { true }
        cameraAllowed = live ? { await CallCamera.allowed() } : { true }
        let renderer = VideoRenderer(requestKeyframe: service.requestKeyframe, onOrientation: { _ in })
        remoteVideo = renderer
        let keyframes = KeyframeRelay()
        self.keyframes = keyframes
        service.connect(CallSinks(
            playout: playout,
            onCall: { [weak self] call in self?.update(call) },
            onCallLog: { [weak self] entry in self?.history.add(entry) },
            onVideo: { frame in
                renderer.enqueue(frame.data, keyframe: frame.keyframe, orientation: frame.orientation)
            },
            onKeyframeNeeded: { keyframes.camera?.requestKeyframe() }
        ))
        renderer.orientationChanged = { [weak self] turns in
            MainActor.assumeIsolated { self?.remoteOrientation = turns }
        }
    }

    /// Hands the camera to the bridge's thread for keyframe requests.
    @ObservationIgnored private let keyframes: KeyframeRelay

    /// A call is ringing or going; a new one cannot start.
    public var isBusy: Bool {
        guard let call else { return false }
        return !call.phase.isEnded
    }

    // MARK: Intents

    /// Calls a person's chat, with our camera on for a video call.
    public func place(chat: String, video: Bool = false) async {
        guard !isLocked, !isBusy else { return }
        guard await microphoneAllowed() else { return deniedMicrophone() }
        let video = await cameraPermission(requested: video)
        guard !isLocked, !isBusy else { return }
        if video { cameraPermitted = true }
        if !service.place(chat: chat, video: video) {
            onNotice(.error, String(localized: "Could not start the call. Check the connection and try again."))
        }
    }

    /// Answers the ringing call, with our camera on if `video`.
    public func answer(video: Bool = false) async {
        guard let call, call.phase == .ringing else { return }
        await answer(call.session, video: video)
    }

    /// Ends the call that goes and answers the waiting one, with voice.
    public func answerWaiting() async {
        guard let waiting else { return }
        await answer(waiting.session, video: false)
    }

    private func answer(_ session: UInt64, video: Bool) async {
        guard await microphoneAllowed() else {
            deniedMicrophone()
            service.end(session: session)
            return
        }
        let video = await cameraPermission(requested: video)
        guard call?.session == session || waiting?.session == session else { return }
        if video { cameraPermitted = true }
        service.answer(session: session, video: video)
    }

    /// Turns our camera on or off: on a voice call, turning it on asks the
    /// other side to switch to video, or accepts when they asked.
    public func toggleCamera() async {
        guard !isLocked, let call, isBusy, call.phase != .ringing else { return }
        if !call.camera, !(await cameraPermission(requested: true)) { return }
        guard !isLocked, self.call?.session == call.session, isBusy else { return }
        if !call.camera { cameraPermitted = true }
        service.setCamera(!call.camera)
    }

    /// Existing call audio may continue while the local screen is locked.
    /// Video capture stays off after unlocking until the person turns it on.
    public func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        guard locked else { return }
        cameraPermitted = false
        let wasOn = call?.camera == true
        call?.camera = false
        followCamera()
        if wasOn { service.setCamera(false) }
    }

    private func cameraPermission(requested: Bool) async -> Bool {
        guard requested, !isLocked else { return false }
        let allowed = await cameraAllowed()
        guard !isLocked else { return false }
        return allowed || deniedCamera()
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
            self.endedAt = nil
        }
    }

    private func show(_ new: CallInfo) {
        if call?.session != new.session {
            connectedAt = nil
            endedAt = nil
        }
        if new.phase == .active, connectedAt == nil { connectedAt = .now }
        if new.phase.isEnded, endedAt == nil { endedAt = .now }
        var visible = new
        if visible.camera, isLocked || !cameraPermitted {
            visible.camera = false
            service.setCamera(false)
        }
        call = visible
    }

    #if DEBUG
    /// Shows `call` as if the bridge had reported it, without sound or the
    /// network, to look at the call window.
    public func debugShow(_ call: CallInfo?, waiting: CallInfo? = nil) {
        self.call = call
        self.waiting = waiting
        let talked = call?.phase == .active || call?.phase.isEnded == true
        connectedAt = talked ? .now.addingTimeInterval(-75) : nil
        endedAt = call?.phase.isEnded == true ? .now : nil
    }
    #endif

    /// Starts and stops the sound and the cameras for what rings and goes now.
    private func follow() {
        followCamera()
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

    /// Says why the camera stays off; `false`, for the call to go on with voice.
    private func deniedCamera() -> Bool {
        onNotice(.error, String(localized: "ZapFast needs the camera for video calls. Allow it in System Settings › Privacy & Security › Camera."))
        return false
    }

    /// Our camera runs while the call with media has it on.
    private func followCamera() {
        let wanted: Bool = switch call?.phase {
        case .calling, .connecting, .active: !isLocked && cameraPermitted && call?.camera == true
        default: false
        }
        if !wanted, let camera {
            camera.stop()
            self.camera = nil
            keyframes.camera = nil
        }
        if call == nil || call?.phase.isEnded == true {
            remoteVideo.reset()
            remoteOrientation = 0
        }
        guard wanted, camera == nil, live else { return }
        let started = CallCamera(frameRate: Int(callVideoFrameRate()), send: service.camera)
        guard started.start() else {
            onNotice(.error, String(localized: "No camera was found for the video call."))
            service.setCamera(false)
            return
        }
        camera = started
        keyframes.camera = started
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

/// The camera, where the bridge's thread can reach it to ask for a keyframe.
nonisolated final class KeyframeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var current: CallCamera?

    var camera: CallCamera? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
