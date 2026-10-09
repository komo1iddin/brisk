import AVFoundation
import Foundation

/// The soft sound of a message leaving, in the spirit of Telegram's: a
/// short, round "bloop" whose pitch lifts as it fades.
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
            player?.volume = 0.5
            player?.prepareToPlay()
        }
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }

    nonisolated static let rate = 44_100.0

    /// The sound, in samples from -1 to 1, its loudest at `peak`.
    ///
    /// A soft, round "bloop" rather than a hiss: a tone that glides up from
    /// 360 Hz to about 780 Hz as it fades (with a little of its second and
    /// third harmonics for warmth), a low body at 140 Hz under its start,
    /// and a breath of air low-passed below 900 Hz so nothing in it is
    /// sharp. Every part eases in over a few milliseconds and the end fades
    /// to nothing, so it neither clicks on nor off.
    nonisolated static func samples() -> [Float] {
        let duration = 0.26
        let count = Int(rate * duration)
        var out = [Float](repeating: 0, count: count)
        var phase: Double = 0
        var bodyPhase: Double = 0
        var seed: UInt32 = 0x9E37_79B9
        var air: Double = 0
        let airPole = exp(-2 * Double.pi * 900 / rate)
        func ease(_ t: Double, _ attack: Double) -> Double {
            t >= attack ? 1 : 0.5 - 0.5 * cos(Double.pi * t / attack)
        }
        for index in 0..<count {
            let t = Double(index) / rate
            // The tone.
            let frequency = 360 + 420 * (1 - exp(-t / 0.035))
            phase += 2 * Double.pi * frequency / rate
            let tone = sin(phase) + 0.18 * sin(2 * phase) + 0.05 * sin(3 * phase)
            let toneEnvelope = ease(t, 0.006) * exp(-t / 0.075)
            // The body.
            bodyPhase += 2 * Double.pi * 140 / rate
            let body = sin(bodyPhase) * ease(t, 0.003) * exp(-t / 0.03)
            // The air: noise through a one-pole low-pass.
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(Int32(bitPattern: seed)) / Double(Int32.max)
            air = airPole * air + (1 - airPole) * noise
            let airEnvelope = ease(t, 0.008) * exp(-t / 0.03)
            var sample = tone * toneEnvelope + 0.18 * body + 0.9 * air * airEnvelope
            // The last 25 ms fade out.
            let left = duration - t
            if left < 0.025 { sample *= 0.5 - 0.5 * cos(Double.pi * left / 0.025) }
            out[index] = Float(sample)
        }
        let loudest = out.map(abs).max() ?? 1
        let scale = loudest > 0 ? peak / loudest : 1
        return out.map { $0 * scale }
    }

    nonisolated static let peak: Float = 0.45

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
