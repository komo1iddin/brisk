import AVFoundation
import Foundation
import Observation
import ZapFastBridge

/// Records a voice message from the default input as mono samples at the
/// rate upstream encodes (`voiceSampleRate()`); the worker does the Opus
/// encoding and the waveform. A take can pause, which lets go of the
/// microphone, be listened to while paused, and go on.
@Observable
public final class VoiceRecorder {
    public enum State: Equatable {
        case idle
        /// Recording since `since`, after `earlier` seconds recorded before
        /// the last pause.
        case recording(since: Date, earlier: TimeInterval)
        /// Paused with `elapsed` seconds recorded.
        case paused(elapsed: TimeInterval)
        /// Microphone access was refused in System Settings.
        case denied
    }

    public private(set) var state: State = .idle
    /// Recent input levels, 0...1, newest last, for a live meter.
    public private(set) var levels: [Float] = []
    /// When listening back to a paused take began, while it plays.
    public private(set) var previewStarted: Date?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var samples = SampleBuffer()
    @ObservationIgnored private var converter: AVAudioConverter?
    @ObservationIgnored private var preview: AVAudioEngine?

    public init() {}

    /// A take is open, recording or paused.
    public var isRecording: Bool {
        switch state {
        case .recording, .paused: true
        case .idle, .denied: false
        }
    }

    public var isPaused: Bool {
        if case .paused = state { true } else { false }
    }

    public var isPreviewing: Bool {
        previewStarted != nil
    }

    /// Seconds recorded so far.
    public func elapsed(at now: Date = .now) -> TimeInterval {
        switch state {
        case let .recording(since, earlier): earlier + max(0, now.timeIntervalSince(since))
        case let .paused(elapsed): elapsed
        case .idle, .denied: 0
        }
    }

    /// Asks for the microphone if needed and starts. Returns whether it did.
    @discardableResult
    public func start() async -> Bool {
        guard !isRecording else { return true }
        guard await Self.microphoneAllowed() else {
            state = .denied
            return false
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
              let target = AVAudioFormat(standardFormatWithSampleRate: Double(voiceSampleRate()), channels: 1),
              let converter = AVAudioConverter(from: format, to: target) else { return false }

        samples = SampleBuffer()
        levels = []
        self.converter = converter
        let tap = Self.makeTap(converter: converter, target: target, samples: samples) { [weak self] level in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.push(level) }
            }
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: tap)
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
        state = .recording(since: .now, earlier: 0)
        return true
    }

    /// Stops listening, keeping what was recorded. The microphone is let
    /// go, so the system's indicator goes out too.
    public func pause() {
        guard case .recording = state else { return }
        let elapsed = elapsed()
        engine.stop()
        state = .paused(elapsed: elapsed)
    }

    /// Goes on recording after a pause. Returns whether it could.
    @discardableResult
    public func resume() -> Bool {
        guard case let .paused(elapsed) = state else { return false }
        stopPreview()
        converter?.reset()
        do {
            try engine.start()
        } catch {
            return false
        }
        state = .recording(since: .now, earlier: elapsed)
        return true
    }

    /// Plays a paused take from the start, or stops it playing.
    public func togglePreview() {
        if isPreviewing {
            stopPreview()
            return
        }
        guard isPaused else { return }
        let recorded = samples.snapshot()
        guard !recorded.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(voiceSampleRate()), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(recorded.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(recorded.count)
        recorded.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: recorded.count) }

        let output = AVAudioEngine()
        let player = AVAudioPlayerNode()
        output.attach(player)
        output.connect(player, to: output.mainMixerNode, format: format)
        do {
            try output.start()
        } catch {
            return
        }
        let started = Date.now
        Self.schedule(buffer, on: player) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A later preview is not this one's to stop.
                    if self?.previewStarted == started { self?.stopPreview() }
                }
            }
        }
        player.play()
        preview = output
        previewStarted = started
    }

    /// Stops and returns what was recorded.
    public func finish() -> [Float] {
        guard isRecording else { return [] }
        stopPreview()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        state = .idle
        return samples.take()
    }

    public func cancel() {
        _ = finish()
        levels = []
    }

    private func stopPreview() {
        preview?.stop()
        preview = nil
        previewStarted = nil
    }

    private func push(_ level: Float) {
        guard case .recording = state else { return }
        levels.append(level)
        if levels.count > 48 { levels.removeFirst(levels.count - 48) }
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    /// Loudness for the meter: the buffer's RMS in decibels, from -50 dB
    /// (silence, the dotted baseline) to full scale, so bars move with the
    /// voice instead of jumping to the top at every peak.
    nonisolated static func level(of chunk: UnsafeBufferPointer<Float>) -> Float {
        guard !chunk.isEmpty else { return 0 }
        let power = chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.count)
        let decibels = 10 * log10(max(power, 1e-10))
        return min(1, max(0, (decibels + 50) / 50))
    }

    /// The player's completion runs on an audio thread, so it is set up
    /// outside the main actor.
    nonisolated private static func schedule(
        _ buffer: AVAudioPCMBuffer,
        on player: AVAudioPlayerNode,
        done: @escaping @Sendable () -> Void
    ) {
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in done() }
    }

    /// The tap runs on the audio thread, so it is built outside the main
    /// actor: converts each buffer to the target format, keeps the samples,
    /// and reports a level.
    nonisolated private static func makeTap(
        converter: AVAudioConverter,
        target: AVAudioFormat,
        samples: SampleBuffer,
        level: @escaping @Sendable (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            nonisolated(unsafe) var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }
            let chunk = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
            samples.append(chunk)
            level(Self.level(of: chunk))
        }
    }
}

/// Samples written by the audio thread and taken by the main actor.
nonisolated private final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []

    func append(_ chunk: UnsafeBufferPointer<Float>) {
        lock.withLock { storage.append(contentsOf: chunk) }
    }

    /// A copy, leaving the samples for the take to go on.
    func snapshot() -> [Float] {
        lock.withLock { storage }
    }

    func take() -> [Float] {
        lock.withLock {
            defer { storage = [] }
            return storage
        }
    }
}
