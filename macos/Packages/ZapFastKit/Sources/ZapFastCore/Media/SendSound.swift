import AVFoundation
import Foundation

/// Which sound a message makes as it leaves.
public enum SendSoundStyle: String, CaseIterable, Sendable {
    /// The shortest and softest: a low breath of air.
    case breath
    /// A fuller swoosh that opens up and passes.
    case air
    /// The swoosh, ending on a soft low landing.
    case airLanding
    case none
}

/// The quiet sound of a message leaving: air, not a note. A tone that
/// glides reads as a toy, and a resonant sweep as a hiss, so this is noise
/// through a plain low-pass with no resonance (Butterworth), whose cutoff
/// opens and closes once while it swells and fades, with the rumble under
/// 120 Hz taken out.
///
/// It is made here rather than shipped: a few thousand samples,
/// synthesised once into an in-memory WAV, so no sound file of anyone
/// else's is copied into the app.
@MainActor
public enum SendSound {
    private static var players: [SendSoundStyle: AVAudioPlayer] = [:]

    /// Plays `style`, quietly, from its start.
    public static func play(_ style: SendSoundStyle) {
        // Tests send messages too; only the app makes a sound.
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.komoliddin.") == true,
              let shape = Shape(style) else { return }
        let player = players[style] ?? {
            let made = try? AVAudioPlayer(data: wav(samples(shape), rate: rate))
            made?.volume = 0.45
            made?.prepareToPlay()
            players[style] = made
            return made
        }()
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }

    nonisolated static let rate = 44_100.0
    nonisolated static let peak: Float = 0.35

    /// How one style swells, fades and brightens.
    struct Shape: Sendable {
        var duration: Double
        /// Seconds to the loudest point, and the fade's time constant after.
        var rise: Double
        var decay: Double
        /// The low-pass cutoff at the start, at its brightest, and at the end.
        var low: Double
        var high: Double
        var end: Double
        var brightestAt: Double
        /// A soft thud as the air settles.
        var landing: Bool

        nonisolated init?(_ style: SendSoundStyle) {
            switch style {
            case .breath:
                self.init(duration: 0.15, rise: 0.035, decay: 0.035, low: 250, high: 1_300, end: 600, brightestAt: 0.05, landing: false)
            case .air:
                self.init(duration: 0.19, rise: 0.05, decay: 0.045, low: 350, high: 1_600, end: 700, brightestAt: 0.065, landing: false)
            case .airLanding:
                self.init(duration: 0.21, rise: 0.05, decay: 0.045, low: 350, high: 1_600, end: 700, brightestAt: 0.065, landing: true)
            case .none:
                return nil
            }
        }

        nonisolated init(
            duration: Double, rise: Double, decay: Double, low: Double, high: Double, end: Double,
            brightestAt: Double, landing: Bool
        ) {
            (self.duration, self.rise, self.decay) = (duration, rise, decay)
            (self.low, self.high, self.end, self.brightestAt, self.landing) = (low, high, end, brightestAt, landing)
        }
    }

    /// The sound, in samples from -1 to 1, its loudest at `peak`.
    nonisolated static func samples(_ shape: Shape) -> [Float] {
        let count = Int(rate * shape.duration)
        var out = [Float](repeating: 0, count: count)
        var seed: UInt32 = 0x2545_F491
        var (x1, x2, y1, y2) = (0.0, 0.0, 0.0, 0.0)
        var (highIn, highOut) = (0.0, 0.0)
        let highPole = exp(-2 * Double.pi * 120 / rate)
        for index in 0..<count {
            let t = Double(index) / rate
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let white = Double(Int32(bitPattern: seed)) / Double(Int32.max)
            let cutoff = t < shape.brightestAt
                ? shape.low * pow(shape.high / shape.low, t / shape.brightestAt)
                : shape.high * pow(shape.end / shape.high, min(1, (t - shape.brightestAt) / (shape.duration - shape.brightestAt)))
            // A two-pole low-pass, Q 1/√2: no peak at the cutoff to whistle.
            let w = 2 * Double.pi * cutoff / rate
            let alpha = sin(w) / (2 * 0.707_1)
            let cosine = cos(w)
            let a0 = 1 + alpha
            let b0 = (1 - cosine) / 2 / a0
            let b1 = (1 - cosine) / a0
            let a1 = -2 * cosine / a0
            let a2 = (1 - alpha) / a0
            let low = b0 * white + b1 * x1 + b0 * x2 - a1 * y1 - a2 * y2
            (x2, x1, y2, y1) = (x1, white, y1, low)
            // And a one-pole high-pass under 120 Hz.
            let air = highPole * (highOut + low - highIn)
            (highIn, highOut) = (low, air)
            let envelope = t < shape.rise
                ? 0.5 - 0.5 * cos(Double.pi * t / shape.rise)
                : exp(-(t - shape.rise) / shape.decay)
            var sample = air * envelope
            if shape.landing {
                // Felt more than heard: 110 Hz, gone in about 16 ms.
                let at = shape.brightestAt + 0.05
                if t >= at {
                    let u = t - at
                    sample += 0.22 * sin(2 * Double.pi * 110 * u) * (1 - exp(-u / 0.002)) * exp(-u / 0.016)
                }
            }
            // The last 20 ms fade to silence.
            let left = shape.duration - t
            if left < 0.02 { sample *= 0.5 - 0.5 * cos(Double.pi * left / 0.02) }
            out[index] = Float(sample)
        }
        let loudest = out.map(abs).max() ?? 1
        let scale = loudest > 0 ? peak / loudest : 1
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
