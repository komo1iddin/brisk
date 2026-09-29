import AVFoundation
import Foundation
import Observation
import ZapFastBridge

/// Plays one voice message or audio attachment at a time, in the app.
///
/// WhatsApp voice notes are Opus in OGG, which AVFoundation does not open,
/// so they decode through upstream's decoder (`decodeVoice`) into a PCM
/// buffer; other audio decodes with `AVAudioFile`. Playback runs through an
/// `AVAudioUnitTimePitch`, which speeds speech up without raising its pitch.
@Observable
public final class VoicePlayer {
    public private(set) var current: MessageKey?
    public private(set) var isPlaying = false
    /// Seconds into the current clip.
    public private(set) var position: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    /// A clip being decoded before it starts.
    public private(set) var preparing: MessageKey?
    public private(set) var failure: String?

    /// Called on the main actor when a clip plays to its end.
    @ObservationIgnored public var onFinished: ((MessageKey) -> Void)?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private let pitch = AVAudioUnitTimePitch()
    @ObservationIgnored private var buffer: AVAudioPCMBuffer?
    /// Frame the current segment started from, for position and seeking.
    @ObservationIgnored private var segmentStart: AVAudioFramePosition = 0
    /// Bumped whenever playback is rescheduled, so a stale completion
    /// callback from a stopped segment is ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init() {
        engine.attach(node)
        engine.attach(pitch)
    }

    public func isCurrent(_ key: MessageKey) -> Bool {
        current == key
    }

    /// Fraction of the current clip played, for a waveform's progress.
    public func progress(of key: MessageKey) -> Double {
        guard current == key, duration > 0 else { return 0 }
        return min(1, position / duration)
    }

    /// Plays `url`, or pauses and resumes it if it is already current.
    public func toggle(_ key: MessageKey, url: URL, opus: Bool, speed: Float) async {
        if current == key, buffer != nil {
            isPlaying ? pause() : resume()
            return
        }
        stop()
        preparing = key
        failure = nil
        let decoded = await Self.decode(url, opus: opus)
        guard preparing == key else { return }
        preparing = nil
        switch decoded {
        case .success(let buffer):
            start(buffer, key: key, speed: speed)
        case .failure(let error):
            failure = error.localizedDescription
        }
    }

    public func setSpeed(_ speed: Float) {
        pitch.rate = speed
    }

    /// Jumps to `fraction` of the current clip.
    public func seek(to fraction: Double) {
        guard let buffer else { return }
        let frame = AVAudioFramePosition(Double(buffer.frameLength) * min(max(fraction, 0), 0.999))
        let wasPlaying = isPlaying
        schedule(from: frame)
        if wasPlaying { node.play() } else { position = seconds(frame) }
    }

    public func stop() {
        generation += 1
        ticker?.cancel()
        node.stop()
        engine.stop()
        buffer = nil
        current = nil
        preparing = nil
        isPlaying = false
        position = 0
        duration = 0
    }

    // MARK: Playback

    private func start(_ buffer: AVAudioPCMBuffer, key: MessageKey, speed: Float) {
        self.buffer = buffer
        current = key
        duration = Double(buffer.frameLength) / buffer.format.sampleRate
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(pitch)
        engine.connect(node, to: pitch, format: buffer.format)
        engine.connect(pitch, to: engine.mainMixerNode, format: buffer.format)
        pitch.rate = speed
        do {
            try engine.start()
        } catch {
            failure = error.localizedDescription
            stop()
            return
        }
        schedule(from: 0)
        resume()
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let buffer else { return }
        generation += 1
        let scheduled = generation
        node.stop()
        segmentStart = frame
        let remaining = AVAudioFrameCount(max(0, AVAudioFramePosition(buffer.frameLength) - frame))
        guard remaining > 0 else { return }
        let file = Self.segmentSource(buffer, from: frame, count: remaining)
        node.scheduleBuffer(file, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.segmentEnded(scheduled) }
            }
        }
    }

    private func segmentEnded(_ scheduled: Int) {
        guard scheduled == generation, let key = current else { return }
        stop()
        onFinished?(key)
    }

    private func pause() {
        node.pause()
        isPlaying = false
        ticker?.cancel()
    }

    private func resume() {
        if !engine.isRunning { try? engine.start() }
        node.play()
        isPlaying = true
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func tick() {
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return }
        position = min(duration, seconds(segmentStart + playerTime.sampleTime))
    }

    private func seconds(_ frame: AVAudioFramePosition) -> TimeInterval {
        guard let buffer else { return 0 }
        return Double(frame) / buffer.format.sampleRate
    }

    // MARK: Decoding

    /// A copy of `buffer` from `frame` on. Copying keeps scheduling simple;
    /// voice notes are short enough that it costs nothing noticeable.
    private static func segmentSource(
        _ buffer: AVAudioPCMBuffer,
        from frame: AVAudioFramePosition,
        count: AVAudioFrameCount
    ) -> AVAudioPCMBuffer {
        guard frame > 0, let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count),
              let source = buffer.floatChannelData, let target = copy.floatChannelData else { return buffer }
        copy.frameLength = count
        for channel in 0..<Int(buffer.format.channelCount) {
            target[channel].update(from: source[channel].advanced(by: Int(frame)), count: Int(count))
        }
        return copy
    }

    @concurrent
    private static func decode(_ url: URL, opus: Bool) async -> Result<AVAudioPCMBuffer, Error> {
        do {
            if opus {
                let samples = try decodeVoice(path: url.path(percentEncoded: false))
                return .success(try pcm(samples, rate: Double(voiceSampleRate())))
            }
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            ) else { throw PlaybackError.unreadable }
            try file.read(into: buffer)
            return .success(buffer)
        } catch {
            return .failure(error)
        }
    }

    nonisolated private static func pcm(_ samples: [Float], rate: Double) throws -> AVAudioPCMBuffer {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw PlaybackError.unreadable }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    enum PlaybackError: LocalizedError {
        case unreadable
        var errorDescription: String? { String(localized: "This recording could not be read.") }
    }
}
