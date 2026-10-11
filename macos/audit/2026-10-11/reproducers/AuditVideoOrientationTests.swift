import Foundation
import Testing
@testable import ZapFastCore

@MainActor
struct AuditVideoOrientationTests {
    final class Witness {
        var rotations: [UInt8] = []
    }

    @Test func anotherCallWithTheSameRotationNotifiesAgain() async {
        let witness = Witness()
        let renderer = VideoRenderer(requestKeyframe: {}, onOrientation: { _ in })
        renderer.orientationChanged = { [witness] rotation in
            MainActor.assumeIsolated { witness.rotations.append(rotation) }
        }
        renderer.enqueue(Data(), keyframe: false, orientation: 1)
        try? await Task.sleep(for: .milliseconds(100))
        renderer.reset()
        renderer.enqueue(Data(), keyframe: false, orientation: 1)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(witness.rotations == [1, 1])
    }
}
