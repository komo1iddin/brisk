import AVFoundation
import Foundation
import OSLog
import Synchronization
import ZapFastBridge

/// A call's sound: the microphone in and the other side out, through one
/// engine with the system's voice processing, which cancels the speaker's
/// echo from the microphone and evens out the voice. The bridge takes and
/// gives 16 kHz mono frames of `callFrameSamples()`; this converts to and
/// from whatever the hardware runs at.
final class CallAudio {
    private var engine: AVAudioEngine?
    private var ringback: AVAudioPlayerNode?
    private let log = Logger(subsystem: "ZapFast", category: "Calls")

    var isRunning: Bool { engine != nil }

    /// Starts the microphone and the speaker. `send` gets each microphone
    /// frame on an audio thread; `playout` is read for the speaker.
    func start(playout: PlayoutBuffer, send: @escaping @Sendable ([Int16]) -> Void) -> Bool {
        guard engine == nil else { return true }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            // Without it the call still works, with the echo of a speakerphone.
            log.warning("calls: voice processing is unavailable")
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
              let wire = AVAudioFormat(standardFormatWithSampleRate: CallTones.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: format, to: wire) else {
            log.error("calls: the microphone has no usable format")
            return false
        }
        converter.downmix = true
        let frame = Int(callFrameSamples())
        input.installTap(
            onBus: 0, bufferSize: 1024, format: format,
            block: Self.makeTap(converter: converter, wire: wire, frame: frame, send: send)
        )

        let speaker = AVAudioSourceNode(format: wire, renderBlock: Self.makeRender(playout))
        engine.attach(speaker)
        engine.connect(speaker, to: engine.mainMixerNode, format: wire)

        let ringback = AVAudioPlayerNode()
        engine.attach(ringback)
        engine.connect(ringback, to: engine.mainMixerNode, format: wire)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            log.error("calls: the audio engine did not start")
            return false
        }
        self.engine = engine
        self.ringback = ringback
        return true
    }

    func stop() {
        guard let engine else { return }
        ringback?.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Lets the hardware leave voice processing, which lowers other apps.
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        self.engine = nil
        ringback = nil
    }

    /// Plays the ringback while calling; it goes through the call's own
    /// engine, so the echo canceller keeps it out of the microphone.
    func setRingback(_ on: Bool) {
        guard let ringback else { return }
        if on, !ringback.isPlaying, let buffer = CallTones.ringback() {
            ringback.scheduleBuffer(buffer, at: nil, options: .loops)
            ringback.play()
        } else if !on, ringback.isPlaying {
            ringback.stop()
        }
    }

    /// Runs on the audio thread: converts each buffer to the wire format and
    /// hands on whole frames.
    nonisolated private static func makeTap(
        converter: AVAudioConverter,
        wire: AVAudioFormat,
        frame: Int,
        send: @escaping @Sendable ([Int16]) -> Void
    ) -> AVAudioNodeTapBlock {
        let pending = Mutex<[Int16]>([])
        return { buffer, _ in
            let ratio = wire.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: capacity) else { return }
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
            let samples = UnsafeBufferPointer(start: channel, count: Int(output.frameLength)).map {
                Int16(max(-1, min(1, $0)) * 32767)
            }
            let frames: [[Int16]] = pending.withLock { pending in
                pending.append(contentsOf: samples)
                var whole: [[Int16]] = []
                while pending.count >= frame {
                    whole.append(Array(pending.prefix(frame)))
                    pending.removeFirst(frame)
                }
                return whole
            }
            for samples in frames { send(samples) }
        }
    }

    /// Runs on the render thread.
    nonisolated private static func makeRender(_ playout: PlayoutBuffer) -> AVAudioSourceNodeRenderBlock {
        return { _, _, frameCount, bufferList in
            // The format is mono, so there is one buffer.
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            if let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) {
                playout.read(into: data, frames: Int(frameCount))
            }
            return noErr
        }
    }
}

/// The ring of an incoming call, on its own engine since no call audio runs
/// yet.
final class Ringer {
    private var engine: AVAudioEngine?

    func start() {
        guard engine == nil, let buffer = CallTones.ring() else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        do {
            try engine.start()
        } catch {
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        self.engine = engine
    }

    func stop() {
        engine?.stop()
        engine = nil
    }
}
