import Darwin
import Foundation
import Testing
@testable import ZapFastCore

struct HangMonitorTests {
    /// A thread stopped in a wait is read from outside, innermost frame
    /// first, down to where it started.
    @Test func readsAnotherThreadsStack() {
        let ready = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var port: thread_t = 0
        let thread = Thread {
            port = pthread_mach_thread_np(pthread_self())
            ready.signal()
            release.wait()
        }
        thread.start()
        ready.wait()
        // Let it reach the wait.
        Thread.sleep(forTimeInterval: 0.05)

        let sampler = StackSampler(thread: port)
        let stack = sampler.sample()
        release.signal()

        #expect(stack.count >= 3)
        let frames = StackSampler.describe(stack)
        #expect(frames.first?.contains("libsystem_kernel.dylib+0x") == true)
        #expect(frames.contains { $0.contains("_pthread_start") || $0.contains("thread_start") })
    }
}
