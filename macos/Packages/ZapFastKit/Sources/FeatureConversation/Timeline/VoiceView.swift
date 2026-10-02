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
/// button (a spinner while it downloads or decodes), the sender's waveform
/// with what was played drawn solid, the time played or the length, and
/// beside it the recorder's photo with a microphone, which the speed takes
/// over while it plays. A click on the waveform seeks.
final class VoiceView: NSView {
    weak var cell: BubbleCell?
    private(set) var voiceLayout: BubbleLayout.VoiceLayout?
    private var messageID: String?
    private var state = VoiceState()

    private let button = SymbolLayer()
    private let spinner = NSProgressIndicator()
    private let wave = WaveformLayer()
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
        for sublayer in [button, wave, time, avatar.layer, mic, speed] as [CALayer] { layer?.addSublayer(sublayer) }
        for sublayer in [button, wave, time, mic, speed, speedText] as [CALayer] {
            sublayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull(), "colors": NSNull()]
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.alphaValue = 0
        addSubview(spinner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func configure(_ layout: BubbleLayout.VoiceLayout, messageID: String) {
        if messageID != self.messageID { state = VoiceState() }
        self.messageID = messageID
        voiceLayout = layout
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        button.frame = layout.button
        wave.frame = layout.waveform
        wave.samples = [UInt8](layout.voice.waveform)
        time.frame = layout.time
        if let side = layout.side {
            avatar.configure(personID: layout.voice.recorderID, name: layout.voice.recorderName, frame: side)
            speed.frame = CGRect(x: side.minX, y: side.midY - 13, width: side.width, height: 26)
            speed.cornerRadius = 13
            mic.frame = CGRect(x: side.minX - 2, y: side.maxY - 14, width: 16, height: 16)
        }
        CATransaction.commit()
        spinner.frame = CGRect(x: layout.button.midX - 8, y: layout.button.midY - 8, width: 16, height: 16)
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
        let symbol = if voice.path == nil {
            switch state.failure {
            case nil: "arrow.down.circle.fill"
            case .some(let failure): failure.isFinal ? "exclamationmark.circle.fill" : "arrow.clockwise.circle.fill"
            }
        } else {
            state.current && state.playing ? "pause.circle.fill" : "play.circle.fill"
        }
        toolTip = voice.path == nil ? state.failure?.explanation : nil
        let redrawn = button.configure(symbol: symbol, pointSize: 30, weight: .regular, palette: [color])
        if redrawn, animated, !state.busy, !before.busy { crossfade(button) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        button.opacity = state.busy ? 0 : 1
        wave.color = color
        wave.progress = state.current ? state.progress : 0
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
        wave.setNeedsDisplay()
        if before.busy != state.busy || force {
            // The button and the spinner swap places, each easing out as the other in.
            if animated {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = state.busy ? 1 : 0
                fade.toValue = state.busy ? 0 : 1
                fade.duration = Self.easeTime
                button.add(fade, forKey: "swap")
            }
            if state.busy { spinner.startAnimation(nil) }
            let (spinner, busy) = (spinner, state.busy)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated ? Self.easeTime : 0
                spinner.animator().alphaValue = busy ? 1 : 0
            } completionHandler: {
                // AppKit calls this on the main thread.
                MainActor.assumeIsolated { if !busy { spinner.stopAnimation(nil) } }
            }
        }
        setAccessibilityValue(state.current && state.playing ? String(localized: "Playing") : nil)
    }

    private static let easeTime: CFTimeInterval = 0.16

    /// The layer's new drawing fades in over its old.
    private func crossfade(_ layer: CALayer) {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = Self.easeTime
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "crossfade")
    }

    /// The play button gives a little under the pointer and comes back.
    private func press(_ down: Bool) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let scale = down ? 0.9 : 1.0
        let move = CABasicAnimation(keyPath: "transform.scale")
        move.fromValue = button.presentation()?.value(forKeyPath: "transform.scale") ?? 1
        move.toValue = scale
        move.duration = down ? 0.08 : 0.14
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        button.setValue(scale, forKeyPath: "transform.scale")
        CATransaction.commit()
        button.add(move, forKey: "press")
    }

    /// The recorder's photo, once there is one.
    func showAvatar(url: URL?, version: Int) {
        avatar.show(url: url, version: version)
    }

    func refreshColors() {
        applyAppearance()
        for layer in [button, wave, time, mic, speedText] as [CALayer] { layer.setNeedsDisplay() }
    }

    private func applyAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [button, mic] { layer.appearance = effectiveAppearance }
        for layer in [time, speedText] { layer.appearance = effectiveAppearance }
        wave.appearance = effectiveAppearance
        effectiveAppearance.performAsCurrentDrawingAppearance {
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
        for layer in [button, wave, time, mic, speedText] as [CALayer] {
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

/// The sender's waveform: rounded bars, those before `progress` solid, the
/// rest faint, as `WaveformView` draws them.
nonisolated final class WaveformLayer: CALayer {
    nonisolated(unsafe) var samples: [UInt8] = []
    nonisolated(unsafe) var progress = 0.0
    nonisolated(unsafe) var color: NSColor = .labelColor
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

    override func draw(in context: CGContext) {
        let bars = samples.isEmpty ? Array(repeating: UInt8(20), count: 40) : samples
        let size = bounds.size
        let step = size.width / CGFloat(bars.count)
        nonisolated(unsafe) let context = context
        nonisolated(unsafe) let appearance = appearance
        let (color, progress) = (color, progress)
        MainActor.assumeIsolated {
            withAppKitContext(context, appearance: appearance) {
                let resolved = color.usingColorSpace(.sRGB) ?? color
                for (index, sample) in bars.enumerated() {
                    let height = max(2, size.height * CGFloat(sample) / 100)
                    let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: max(1.5, step * 0.55), height: height)
                    let played = (CGFloat(index) + 0.5) / CGFloat(bars.count) <= progress
                    resolved.withAlphaComponent(resolved.alphaComponent * (played ? 1 : 0.4)).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
                }
            }
        }
    }
}
