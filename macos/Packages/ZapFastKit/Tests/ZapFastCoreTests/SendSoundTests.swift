import Foundation
import Testing
@testable import ZapFastCore

/// The send sound is made in code; it must stay short, soft (nothing
/// sharp in it), and a well-formed WAV.
struct SendSoundTests {
    @Test func isAQuarterOfASecondBelowHalfScale() {
        let samples = SendSound.samples()
        #expect(abs(Double(samples.count) / SendSound.rate - 0.26) < 0.001)
        let peak = samples.map(abs).max() ?? 0
        #expect(abs(peak - SendSound.peak) < 0.001)
        // It starts and ends at silence: no click either way.
        #expect(abs(samples.first ?? 1) < 0.01)
        #expect(abs(samples.last ?? 1) < 0.01)
        // It fades out: the last tenth is near silence.
        let tail = samples.suffix(samples.count / 10).map(abs).max() ?? 1
        #expect(tail < 0.05)
    }

    @Test func isAWav() {
        let data = SendSound.wav([0, 0.5, -0.5], rate: SendSound.rate)
        #expect(data.count == 44 + 6)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
    }
}
