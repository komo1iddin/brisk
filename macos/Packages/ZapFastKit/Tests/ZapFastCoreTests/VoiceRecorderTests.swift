import Foundation
import Testing
@testable import ZapFastCore

@MainActor
struct VoiceRecorderTests {
    private func level(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer(VoiceRecorder.level(of:))
    }

    @Test func silenceSitsOnTheBaselineAndFullScaleFillsTheBar() {
        #expect(level([]) == 0)
        #expect(level(Array(repeating: 0, count: 512)) == 0)
        #expect(level(Array(repeating: 1, count: 512)) == 1)
    }

    @Test func aSpeakingVoiceStaysClearOfBothEnds() {
        // A sine at a tenth of full scale, a voice at speaking distance:
        // RMS about -23 dB, most of the bar without filling it.
        let tone = (0..<4800).map { Float(0.1 * sin(Double($0) * 2 * .pi * 440 / 48000)) }
        let bar = level(tone)
        #expect(bar > 0.6 && bar < 0.8)
        // A single loud click no longer throws the bar to the top.
        var click = Array(repeating: Float(0.01), count: 4800)
        click[100] = 1
        #expect(level(click) < 0.45)
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
