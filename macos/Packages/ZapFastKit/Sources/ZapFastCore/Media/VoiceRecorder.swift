import AVFoundation
import Foundation
import Observation
import ZapFastBridge

/// Records a voice message from the default input as mono samples at the
/// rate upstream encodes (`voiceSampleRate()`); the worker does the Opus
/// encoding and the waveform.
@Observable
public final class VoiceRecorder {
    public enum State: Equatable {
        case idle
        case recording(since: Date)
        /// Microphone access was refused in System Settings.
        case denied
    }

    public private(set) var state: State = .idle
    /// Recent input levels, 0...1, newest last, for a live meter.
    public private(set) var levels: [Float] = []

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var samples = SampleBuffer()

    public init() {}

    public var isRecording: Bool {
        if case .recording = state { true } else { false }
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
        state = .recording(since: .now)
        return true
    }

    /// Stops and returns what was recorded.
    public func finish() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        state = .idle
        return samples.take()
    }

    public func cancel() {
        _ = finish()
        levels = []
    }

    private func push(_ level: Float) {
        guard isRecording else { return }
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
            let peak = chunk.reduce(Float(0)) { max($0, abs($1)) }
            level(min(1, peak * 1.6))
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

    func take() -> [Float] {
        lock.withLock {
            defer { storage = [] }
            return storage
        }
    }
}
