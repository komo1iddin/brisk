import Foundation
import Testing
@testable import ZapFastCore

@MainActor
struct VideoBackpressureTests {
    @Test func burstsDiscardDependentFramesAndRecoverFromTheNewestChain() {
        var inbox = VideoFrameInbox()
        for index in 0..<10_000 {
            inbox.append(.init(data: Data([UInt8(truncatingIfNeeded: index)]), keyframe: false, orientation: 0))
            #expect(inbox.frames.count <= VideoFrameInbox.frameLimit)
        }
        let work = inbox.next()
        #expect(work?.gap == true)
        #expect(work?.frame?.data == Data([UInt8(truncatingIfNeeded: 9992)]))
    }

    @Test func bytesAndSingleUnitSizeAreBoundedAndResetReleasesPendingData() {
        var inbox = VideoFrameInbox()
        for _ in 0..<20 {
            inbox.append(.init(data: Data(count: VideoFrameInbox.unitLimit), keyframe: true, orientation: 0))
            #expect(inbox.bytes <= VideoFrameInbox.byteLimit)
        }
        inbox.append(.init(data: Data(count: VideoFrameInbox.unitLimit + 1), keyframe: false, orientation: 0))
        #expect(inbox.bytes == 0)
        let lost = inbox.next()
        #expect(lost?.gap == true)
        inbox.append(.init(data: Data([1]), keyframe: true, orientation: 3))
        inbox.reset()
        let reset = inbox.next()
        #expect(reset?.reset == true && reset?.stream == 1 && reset?.frame == nil)
        let empty = inbox.next()
        #expect(empty == nil)
    }

    @Test func missingFramesCannotFloodKeyframeRequests() {
        var requests = VideoKeyframeRequests()
        let now = ContinuousClock.now
        let first = requests.shouldRequest(at: now)
        #expect(first)
        for _ in 0..<1000 {
            let repeated = requests.shouldRequest(at: now + .milliseconds(999))
            #expect(!repeated)
        }
        let retry = requests.shouldRequest(at: now + .seconds(1))
        #expect(retry)
    }
}
