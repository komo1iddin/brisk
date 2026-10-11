import Foundation
import Testing
@testable import ZapFastCore

@MainActor
struct VideoRendererTests {
    @MainActor final class Witness {
        var rotations: [UInt8] = []
    }

    private func wait(_ witness: Witness, count: Int) async {
        let end = ContinuousClock.now + .seconds(3)
        while witness.rotations.count < count, ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test(arguments: [UInt8(0), 1, 3])
    func eachCallReportsItsFirstRotationEvenWhenItMatchesTheLast(_ rotation: UInt8) async {
        let witness = Witness()
        let renderer = VideoRenderer(requestKeyframe: {}, onOrientation: { value in
            MainActor.assumeIsolated { witness.rotations.append(value) }
        })
        renderer.enqueue(Data(), keyframe: false, orientation: rotation)
        await wait(witness, count: 1)
        renderer.reset()
        renderer.enqueue(Data(), keyframe: false, orientation: rotation)
        await wait(witness, count: 2)
        #expect(witness.rotations == [rotation, rotation])
    }

    @Test func callbacksQueuedBeforeResetCannotChangeTheNewCall() async {
        let witness = Witness()
        let renderer = VideoRenderer(requestKeyframe: {}, onOrientation: { value in
            MainActor.assumeIsolated { witness.rotations.append(value) }
        })
        // Stay on the main actor until reset, so any old main-queue callback
        // cannot be delivered before the stream has changed.
        renderer.enqueue(Data(), keyframe: false, orientation: 3)
        renderer.reset()
        renderer.enqueue(Data(), keyframe: false, orientation: 1)
        await wait(witness, count: 1)
        #expect(witness.rotations == [1])
    }
}
