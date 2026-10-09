import Foundation
import Testing
@testable import ZapFastCore

/// The send sounds are made in code; each must stay short, quiet, free of
/// clicks, and a well-formed WAV.
struct SendSoundTests {
    @Test(arguments: [SendSoundStyle.breath, .air, .airLanding])
    func isShortQuietAndStartsAndEndsSilent(_ style: SendSoundStyle) throws {
        let shape = try #require(SendSound.Shape(style))
        let samples = SendSound.samples(shape)
        #expect(Double(samples.count) / SendSound.rate < 0.25)
        let peak = samples.map(abs).max() ?? 0
        #expect(abs(peak - SendSound.peak) < 0.001)
        #expect(abs(samples.first ?? 1) < 0.01)
        #expect(abs(samples.last ?? 1) < 0.01)
    }

    @Test func noneMakesNoSound() {
        #expect(SendSound.Shape(.none) == nil)
    }

    @Test func isAWav() {
        let data = SendSound.wav([0, 0.5, -0.5], rate: SendSound.rate)
        #expect(data.count == 44 + 6)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
    }
}
