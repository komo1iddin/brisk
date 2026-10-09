import AVFoundation
import Foundation

/// The soft whoosh of a message leaving, as Telegram plays one: a breath of
/// noise whose pitch sweeps up as it fades, over a small rising pop.
///
/// It is made here rather than shipped: about a fifth of a second of
/// samples, synthesised once into an in-memory WAV, so no sound file of
/// anyone else's is copied into the app.
@MainActor
public enum SendSound {
    private static var player: AVAudioPlayer?

    /// Plays it, quietly, unless it is still playing from a moment ago.
    public static func play() {
        // Tests send messages too; only the app makes a sound.
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.komoliddin.") == true else { return }
        if player == nil {
            player = try? AVAudioPlayer(data: wav(samples(), rate: rate))
            player?.volume = 0.55
            player?.prepareToPlay()
        }
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }

    nonisolated static let rate = 44_100.0

    /// The sound, in samples from -1 to 1, its loudest at half scale.
    nonisolated static func samples() -> [Float] {
        let duration = 0.22
        let count = Int(rate * duration)
        var out = [Float](repeating: 0, count: count)
        // Noise through a band-pass whose centre sweeps up from 450 Hz to
        // 2.6 kHz (a state-variable filter), shaped by a quick rise and a
        // fall of about 60 ms.
        var seed: UInt32 = 0x9E37_79B9
        var low: Double = 0
        var band: Double = 0
        let damping = 1 / 1.4
        for index in 0..<count {
            let t = Double(index) / rate
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(Int32(bitPattern: seed)) / Double(Int32.max)
            let centre = 450 * pow(2_600 / 450, min(1, t / duration))
            let f = 2 * sin(Double.pi * centre / rate)
            low += f * band
            let high = noise - low - damping * band
            band += f * high
            let envelope = (1 - exp(-t / 0.018)) * exp(-t / 0.055)
            out[index] = Float(band * envelope * 0.9)
        }
        // A soft pop under it: a sine gliding from 620 to 1,050 Hz over
        // its first 60 ms, gone in about 20 ms.
        var phase: Double = 0
        for index in 0..<min(count, Int(rate * 0.09)) {
            let t = Double(index) / rate
            let frequency = 620 + 430 * min(1, t / 0.06)
            phase += 2 * Double.pi * frequency / rate
            let envelope = (1 - exp(-t / 0.002)) * exp(-t / 0.02)
            out[index] += Float(sin(phase) * envelope * 0.35)
        }
        let peak = out.map(abs).max() ?? 1
        let scale = peak > 0 ? 0.5 / peak : 1
        return out.map { $0 * scale }
    }

    /// 16-bit mono PCM in a WAV container.
    nonisolated static func wav(_ samples: [Float], rate: Double) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(rate))
        append(UInt32(rate) * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(bytes)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }
}
