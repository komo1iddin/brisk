import AppKit
import ZapFastCore
import ZapFastDesign

/// What a voice message's player shows that changes while it plays.
struct VoiceState: Equatable {
    var current = false
    var playing = false
    /// Decoding before it starts, or downloading.
    var busy = false
    /// Why the file did not come, after a download that failed.
    var failure: DownloadFailure?
    var progress = 0.0
    /// Seconds played, while current.
    var position: TimeInterval = 0
    /// The clip's length once decoded, while current.
    var duration: TimeInterval = 0
    var speed: Float = 1
}

/// A voice message in a drawn bubble, as `AudioContent` shows it: the play
/// button (an arc turning in it while it downloads or decodes), the
/// sender's waveform with what was played drawn solid, the time played or
/// the length, and beside it the recorder's photo with a microphone, which
/// the speed takes over while it plays. A click on the waveform seeks.
///
/// Nothing blinks: the button's glyph morphs (`PlayButtonLayer`), a wait
/// shorter than `busyGrace` shows no arc at all, and the played part of
/// the waveform glides with the clip under Core Animation between the
/// player's position reports.
final class VoiceView: NSView {
    weak var cell: BubbleCell?
    private(set) var voiceLayout: BubbleLayout.VoiceLayout?
    private var messageID: String?
    private var state = VoiceState()

    /// A failed download's symbol, where the button was.
    private let button = SymbolLayer()
    private let play = PlayButtonLayer()
    private let wave = WaveformLayer()
    /// The same bars solid, shown up to the playhead through `playedMask`.
    private let played = WaveformLayer()
    private let playedMask = CALayer()
    private var bubbleColor: NSColor = .windowBackgroundColor
    /// Busy shown, once it has lasted `busyGrace`.
    private var showsBusy = false
    private var busyTask: Task<Void, Never>?
    /// The speed the played part glides at.
    private var glideSpeed: Float?
    private let time = TextLayer()
    private let avatar = AvatarLayers()
    private let mic = SymbolLayer()
    private let speed = CALayer()
    private let speedText = TextLayer()
    private var pressed: Part?

    private enum Part { case button, wave, speed }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        mic.shadowColor = NSColor.black.cgColor
        mic.shadowOpacity = 0.35
        mic.shadowRadius = 1
        mic.shadowOffset = .zero
        speed.addSublayer(speedText)
        played.solid = true
        playedMask.backgroundColor = NSColor.black.cgColor
        playedMask.anchorPoint = CGPoint(x: 0, y: 0.5)
        played.mask = playedMask
        for sublayer in [button, play, wave, played, time, avatar.layer, mic, speed] as [CALayer] { layer?.addSublayer(sublayer) }
        for sublayer in [button, wave, played, playedMask, time, mic, speed, speedText] as [CALayer] {
            sublayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull(), "colors": NSNull(), "transform": NSNull(), "opacity": NSNull()]
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func configure(_ layout: BubbleLayout.VoiceLayout, messageID: String, bubbleColor: NSColor?) {
        if messageID != self.messageID {
            state = VoiceState()
            busyTask?.cancel()
            showsBusy = false
            glideSpeed = nil
        }
        self.messageID = messageID
        voiceLayout = layout
        self.bubbleColor = bubbleColor ?? .windowBackgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        button.frame = layout.button
        play.frame = layout.button
        wave.frame = layout.waveform
        wave.samples = [UInt8](layout.voice.waveform)
        played.frame = layout.waveform
        played.samples = wave.samples
        playedMask.bounds = CGRect(origin: .zero, size: layout.waveform.size)
        playedMask.position = CGPoint(x: 0, y: layout.waveform.height / 2)
        time.frame = layout.time
        if let side = layout.side {
            avatar.configure(personID: layout.voice.recorderID, name: layout.voice.recorderName, frame: side)
            speed.frame = CGRect(x: side.minX, y: side.midY - 13, width: side.width, height: 26)
            speed.cornerRadius = 13
            mic.frame = CGRect(x: side.minX - 2, y: side.maxY - 14, width: 16, height: 16)
        }
        CATransaction.commit()
        mic.configure(symbol: "mic.fill", pointSize: 11, weight: .semibold, palette: [layout.micColor])
        apply(state, force: true)
        applyAppearance()
    }

    /// Playback moved on, or started, stopped or paused.
    func apply(_ new: VoiceState, force: Bool = false) {
        guard force || new != state, let layout = voiceLayout else { return }
        let before = state
        // A change on screen eases; a cell made for another message does not.
        let animated = !force && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        state = new
        let voice = layout.voice
        let color = layout.color
        toolTip = voice.path == nil ? state.failure?.explanation : nil
        updateBusy(force: force)
        showButton(animated: animated)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wave.color = color
        played.color = color
        let total = voice.seconds.map(TimeInterval.init) ?? (state.current ? state.duration : 0)
        let shown = state.current && state.position > 0 ? state.position : total
        let label = Duration.seconds(Int(shown.rounded(.down))).formatted(.time(pattern: .minuteSecond))
        let string = TimelineText.line(label, TimelineText.captionDigits, TimelineText.faded(color, 0.8))
        time.piece = TextPiece(string: string, rect: CGRect(origin: .zero, size: layout.time.size))
        let showsSpeed = state.current && voice.voiceNote && layout.side != nil
        speed.isHidden = !showsSpeed
        avatar.layer.isHidden = showsSpeed || layout.side == nil
        mic.isHidden = avatar.layer.isHidden
        if showsSpeed {
            let label = state.speed == 1 ? "1×" : state.speed == 2 ? "2×" : "1.5×"
            let font = NSFont.monospacedDigitSystemFont(ofSize: TimelineText.callout.pointSize, weight: .semibold)
            let string = TimelineText.line(label, font, color)
            let size = TimelineText.size(string)
            speedText.frame = CGRect(x: ((speed.bounds.width - size.width) / 2).rounded(), y: ((26 - size.height) / 2).rounded(), width: size.width, height: size.height)
            speedText.piece = TextPiece(string: string, rect: CGRect(origin: .zero, size: size))
            speedText.setNeedsDisplay()
        }
        CATransaction.commit()
        time.setNeedsDisplay()
        if force || before.current != state.current || wave.needsRedraw(for: color) {
            wave.setNeedsDisplay()
            played.setNeedsDisplay()
        }
        updateProgress(from: before, animated: animated)
        setAccessibilityValue(state.current && state.playing ? String(localized: "Playing") : nil)
    }

    /// A wait shorter than this (decoding a short clip, a quick download)
    /// shows no arc: the glyph goes straight to the next one.
    static let busyGrace: Duration = .milliseconds(180)

    /// Busy is shown once it has lasted `busyGrace`, and goes at once.
    private func updateBusy(force: Bool) {
        guard state.busy else {
            busyTask?.cancel()
            busyTask = nil
            showsBusy = false
            return
        }
        guard !showsBusy, busyTask == nil else { return }
        if force {
            showsBusy = true
            return
        }
        busyTask = Task { [weak self] in
            try? await Task.sleep(for: Self.busyGrace)
            guard let self, !Task.isCancelled else { return }
            self.busyTask = nil
            guard self.state.busy else { return }
            self.showsBusy = true
            self.showButton(animated: self.window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    /// The glyph for the state: the arc while busy, a failure's symbol
    /// instead of the disc, else download, play or pause.
    private func showButton(animated: Bool) {
        guard let layout = voiceLayout else { return }
        let failed = layout.voice.path == nil && state.failure != nil && !showsBusy
        if failed, let failure = state.failure {
            let symbol = failure.isFinal ? "exclamationmark.circle.fill" : "arrow.clockwise.circle.fill"
            button.configure(symbol: symbol, pointSize: 30, weight: .regular, palette: [layout.color])
        }
        let glyph: PlayButtonLayer.Glyph = if showsBusy {
            .none
        } else if layout.voice.path == nil {
            .download
        } else {
            state.current && state.playing ? .pause : .play
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        button.isHidden = !failed
        play.isHidden = failed
        CATransaction.commit()
        play.show(glyph, animated: animated && !failed)
        play.setSpinning(showsBusy, animated: animated)
    }

    /// The solid bars reach the playhead. While the clip plays they glide
    /// to its end at its speed, under Core Animation, and are put right
    /// only when the player's reports drift from them; otherwise they
    /// stand where the clip is.
    private func updateProgress(from before: VoiceState, animated: Bool) {
        let fraction = CGFloat(state.current ? min(max(state.progress, 0), 1) : 0)
        let gliding = state.current && state.playing && state.duration > 0 && state.position < state.duration
        let shown = (playedMask.presentation() ?? playedMask).value(forKeyPath: "transform.scale.x") as? CGFloat ?? fraction
        if gliding {
            let running = playedMask.animation(forKey: "glide") != nil
            if running, glideSpeed == state.speed, abs(shown - fraction) < 0.03 { return }
            glideSpeed = state.speed
            let remaining = (state.duration - state.position) / Double(max(state.speed, 0.1))
            let glide = CABasicAnimation(keyPath: "transform.scale.x")
            glide.fromValue = fraction
            glide.toValue = 1
            glide.duration = max(remaining, 0.01)
            glide.timingFunction = CAMediaTimingFunction(name: .linear)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playedMask.setValue(1, forKeyPath: "transform.scale.x")
            CATransaction.commit()
            playedMask.add(glide, forKey: "glide")
            return
        }
        glideSpeed = nil
        playedMask.removeAnimation(forKey: "glide")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playedMask.setValue(fraction, forKeyPath: "transform.scale.x")
        CATransaction.commit()
        // A seek while paused eases there; a clip that ended starts over at once.
        if animated, before.current, state.current, abs(shown - fraction) > 0.001 {
            let move = CABasicAnimation(keyPath: "transform.scale.x")
            move.fromValue = shown
            move.toValue = fraction
            move.duration = 0.18
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            playedMask.add(move, forKey: "seek")
        }
    }

    /// The play button gives a little under the pointer and comes back.
    private func press(_ down: Bool) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let scale = down ? 0.88 : 1.0
        let from = play.presentation()?.value(forKeyPath: "transform.scale") ?? 1
        let move: CABasicAnimation
        if down {
            move = CABasicAnimation(keyPath: "transform.scale")
            move.duration = 0.08
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        } else {
            // Back with a little spring.
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.stiffness = 420
            spring.damping = 16
            spring.duration = spring.settlingDuration
            move = spring
        }
        move.fromValue = from
        move.toValue = scale
        for layer in [play, button] as [CALayer] {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.setValue(scale, forKeyPath: "transform.scale")
            CATransaction.commit()
            layer.add(move, forKey: "press")
        }
    }

    /// The recorder's photo, once there is one.
    func showAvatar(url: URL?, version: Int) {
        avatar.show(url: url, version: version)
    }

    func refreshColors() {
        applyAppearance()
        for layer in [button, wave, played, time, mic, speedText] as [CALayer] { layer.setNeedsDisplay() }
    }

    private func applyAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [button, mic] { layer.appearance = effectiveAppearance }
        for layer in [time, speedText] { layer.appearance = effectiveAppearance }
        wave.appearance = effectiveAppearance
        played.appearance = effectiveAppearance
        effectiveAppearance.performAsCurrentDrawingAppearance {
            play.setColors(voiceLayout?.color.cgColor ?? NSColor.labelColor.cgColor, background: bubbleColor.cgColor)
            // `.quaternary` of the bubble's text, as the SwiftUI capsule.
            speed.backgroundColor = TimelineText.faded(voiceLayout?.color ?? .labelColor, 0.12).cgColor
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [button, wave, played, time, mic, speedText] as [CALayer] {
            layer.contentsScale = scale
            layer.setNeedsDisplay()
        }
        avatar.setScale(scale)
    }

    // MARK: Clicks

    private func part(at point: NSPoint) -> Part? {
        guard let layout = voiceLayout else { return nil }
        if layout.button.insetBy(dx: -4, dy: -4).contains(point) { return .button }
        if layout.waveform.insetBy(dx: 0, dy: -4).contains(point) { return .wave }
        if !speed.isHidden, speed.frame.contains(point) { return .speed }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            cell?.mouseDown(with: event)
            return
        }
        pressed = part(at: convert(event.locationInWindow, from: nil))
        if pressed == .button { press(true) }
        if pressed == nil { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let pressed, let id = messageID, let layout = voiceLayout else { return }
        self.pressed = nil
        if pressed == .button { press(false) }
        let point = convert(event.locationInWindow, from: nil)
        switch pressed {
        case .button:
            if part(at: point) == .button { cell?.delegate?.playVoice(inMessage: id) }
        case .wave:
            // Where the drag ended, as the SwiftUI waveform's gesture.
            let fraction = (point.x - layout.waveform.minX) / layout.waveform.width
            cell?.delegate?.seekVoice(inMessage: id, to: Double(min(max(fraction, 0), 1)))
        case .speed:
            if part(at: point) == .speed { cell?.delegate?.cycleVoiceSpeed() }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        superview?.menu(for: event)
    }
}

/// The sender's waveform: rounded bars, faint, or solid for the part
/// played, as `WaveformView` draws them.
nonisolated final class WaveformLayer: CALayer {
    nonisolated(unsafe) var samples: [UInt8] = []
    /// Every bar solid (the played copy), else every bar faint.
    nonisolated(unsafe) var solid = false
    nonisolated(unsafe) var color: NSColor = .labelColor
    nonisolated(unsafe) private var drawnColor: NSColor?
    nonisolated(unsafe) var appearance: NSAppearance?

    override init() {
        super.init()
        contentsFormat = .RGBA8Uint
        contentsScale = 2
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func action(forKey event: String) -> (any CAAction)? { nil }

    /// Whether the bars were drawn in another colour, or not yet.
    func needsRedraw(for color: NSColor) -> Bool {
        drawnColor != color
    }

    override func draw(in context: CGContext) {
        drawnColor = color
        let bars = samples.isEmpty ? Array(repeating: UInt8(20), count: 40) : samples
        let size = bounds.size
        let step = size.width / CGFloat(bars.count)
        nonisolated(unsafe) let context = context
        nonisolated(unsafe) let appearance = appearance
        let (color, solid) = (color, solid)
        MainActor.assumeIsolated {
            withAppKitContext(context, appearance: appearance) {
                let resolved = color.usingColorSpace(.sRGB) ?? color
                for (index, sample) in bars.enumerated() {
                    let height = max(2, size.height * CGFloat(sample) / 100)
                    let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: max(1.5, step * 0.55), height: height)
                    resolved.withAlphaComponent(resolved.alphaComponent * (solid ? 1 : 0.4)).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
                }
            }
        }
    }
}
