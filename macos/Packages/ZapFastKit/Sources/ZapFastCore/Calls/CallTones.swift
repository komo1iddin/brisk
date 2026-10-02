import AVFoundation
import Foundation

/// The two sounds a call makes before anyone talks, drawn rather than
/// bundled: the ring of an incoming call and the ringback heard while
/// calling. Each buffer is one period, for looping.
enum CallTones {
    static let sampleRate = 16_000.0

    /// Two short bursts of a soft chord, then a pause: 3 s.
    static func ring() -> AVAudioPCMBuffer? {
        tone(
            period: 3.0,
            bursts: [(0.0, 0.4), (0.55, 0.4)],
            frequencies: [659.25, 880.0],
            level: 0.22
        )
    }

    /// One long tone, then a longer pause, as networks play it: 5 s.
    static func ringback() -> AVAudioPCMBuffer? {
        tone(period: 5.0, bursts: [(0.0, 1.0)], frequencies: [425.0], level: 0.12)
    }

    /// Two short beeps over a call, when another call rings: 4 s.
    static func waiting() -> AVAudioPCMBuffer? {
        tone(period: 4.0, bursts: [(0.0, 0.2), (0.4, 0.2)], frequencies: [440.0], level: 0.12)
    }

    /// `bursts` are (start, length) in seconds within `period`; each fades
    /// in and out over 15 ms so it does not click.
    static func tone(
        period: Double,
        bursts: [(start: Double, length: Double)],
        frequencies: [Double],
        level: Float
    ) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(period * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        channel.update(repeating: 0, count: Int(frames))
        let fade = 0.015 * sampleRate
        for burst in bursts {
            let first = Int(burst.start * sampleRate)
            let count = Int(burst.length * sampleRate)
            for index in 0 ..< count where first + index < Int(frames) {
                let time = Double(first + index) / sampleRate
                let envelope = min(1, Double(index) / fade, Double(count - index) / fade)
                let wave = frequencies.reduce(0.0) { $0 + sin(2 * .pi * $1 * time) } / Double(frequencies.count)
                channel[first + index] = Float(wave * envelope) * level
            }
        }
        return buffer
    }
}
