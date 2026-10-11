import Foundation
import Synchronization
import Testing
import ZapFastBridge
@testable import ZapFastCore

nonisolated private final class HistoryCenter: CallCenter, @unchecked Sendable {
    let readOnMain = Atomic<Bool>(true)
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { super.init(unsafeFromHandle: handle) }
    override func history(chat: String) -> [CallLogEntry] {
        readOnMain.store(Thread.isMainThread, ordering: .releasing)
        return []
    }
}

@MainActor
struct CallHistoryLoadingTests {
    @Test func theBlockingBridgeReadRunsOffTheMainThread() async {
        let center = HistoryCenter()
        _ = await CallHistoryReader(center).read("fixture")
        let onMain = center.readOnMain.load(ordering: .acquiring)
        #expect(!onMain)
    }
    private final class Reader {
        var starts = 0
        var continuation: CheckedContinuation<[CallLogEntry], Never>?
        func read(_ chat: String) async -> [CallLogEntry] {
            starts += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        func waitForStart() async {
            let deadline = ContinuousClock.now + .seconds(3)
            while continuation == nil, ContinuousClock.now < deadline { await Task.yield() }
        }
        func finish(_ calls: [CallLogEntry]) { continuation?.resume(returning: calls); continuation = nil }
    }

    private func log(_ id: String, at: Int64, outcome: CallOutcome = .missed) -> CallLogEntry {
        CallLogEntry(callId: id, chat: "fixture", fromMe: false, video: false,
                     outcome: outcome, timestamp: at, duration: 0)
    }

    @Test func loadingCoalescesAndNewReportsWinOverTheDiskSnapshot() async {
        let reader = Reader()
        let history = CallHistory(read: reader.read)
        #expect(history.calls(in: "fixture").isEmpty)
        #expect(history.calls(in: "fixture").isEmpty)
        await reader.waitForStart()
        #expect(reader.starts == 1)
        history.add(log("same", at: 2, outcome: .connected))
        history.add(log("new", at: 3))
        reader.finish([log("old", at: 1), log("same", at: 2)])
        let deadline = ContinuousClock.now + .seconds(3)
        while history.calls(in: "fixture").count != 3, ContinuousClock.now < deadline { await Task.yield() }
        #expect(history.calls(in: "fixture").map(\.callId) == ["old", "same", "new"])
        #expect(history.calls(in: "fixture").first { $0.callId == "same" }?.outcome == .connected)
    }

    @Test func cancelledLoadsCannotInstallTheirSnapshot() async {
        let reader = Reader()
        let history = CallHistory(read: reader.read)
        _ = history.calls(in: "fixture")
        await reader.waitForStart()
        history.cancelLoads()
        reader.finish([log("stale", at: 1)])
        _ = history.calls(in: "fixture")
        await reader.waitForStart()
        #expect(reader.starts == 2)
        reader.finish([log("fresh", at: 2)])
        let deadline = ContinuousClock.now + .seconds(3)
        while history.calls(in: "fixture").isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        #expect(history.calls(in: "fixture").map(\.callId) == ["fresh"])
    }
}
