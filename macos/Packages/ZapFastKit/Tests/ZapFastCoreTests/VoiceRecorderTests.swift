import Foundation
import Testing
@testable import ZapFastCore

@MainActor
struct VoiceRecorderTests {
    private func decibels(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer(VoiceRecorder.decibels(of:))
    }

    @Test func loudnessIsTheBuffersRMSInDecibels() {
        #expect(decibels([]) == -100)
        #expect(decibels(Array(repeating: 0, count: 512)) == -100)
        #expect(decibels(Array(repeating: 1, count: 512)) == 0)
        // A sine at a tenth of full scale: RMS about -23 dB.
        let tone = (0..<4800).map { Float(0.1 * sin(Double($0) * 2 * .pi * 440 / 48000)) }
        #expect(abs(decibels(tone) + 23) < 0.2)
    }

    @Test func aQuietVoiceStillFillsTheBarAndRoomNoiseStaysDown() {
        var scale = MeterScale()
        // A voice at -30 dB fills the bar; room noise at -50 dB is the baseline.
        #expect(scale.level(decibels: -30) == 1)
        #expect(scale.level(decibels: -50) == 0)
        #expect(scale.level(decibels: -40) > 0.45)
    }

    @Test func theTopFollowsALouderVoiceAtOnceAndSinksSlowly() {
        var scale = MeterScale()
        #expect(scale.level(decibels: -10) == 1)
        // Just after, a softer word is shorter, not full.
        let softer = scale.level(decibels: -25)
        #expect(softer > 0.5 && softer < 0.7)
        // After a quiet while the top has sunk back, never under -30 dB.
        for _ in 0..<400 { _ = scale.level(decibels: -60) }
        #expect(scale.top == MeterScale.lowestTop)
        #expect(scale.level(decibels: -30) == 1)
    }

    @Test func nothingPausesOrPlaysBeforeATakeStarts() {
        let recorder = VoiceRecorder()
        recorder.pause()
        #expect(recorder.state == .idle)
        #expect(!recorder.resume())
        recorder.togglePreview()
        #expect(!recorder.isPreviewing)
        #expect(recorder.elapsed() == 0)
        #expect(!recorder.isRecording)
    }
}
