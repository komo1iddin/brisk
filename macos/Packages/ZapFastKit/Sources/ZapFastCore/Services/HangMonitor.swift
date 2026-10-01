import Darwin
import Foundation
import OSLog

/// Logs each time the main thread stops answering for a quarter of a
/// second or more, for how long, and where it was (subsystem ZapFast,
/// category Hangs), so a freeze someone saw can be found in the log
/// afterwards next to the events that were arriving (category Events).
///
/// A thread of its own asks the main queue to answer every tenth of a
/// second; an answer that has not come within the limit is a hang, timed
/// until it comes. While it lasts, the main thread's stack is read every
/// quarter of a second: code addresses only, as `image+offset` (and the
/// nearest symbol the image exports), never data.
public nonisolated enum HangMonitor {
    private static let limit = DispatchTimeInterval.milliseconds(250)
    /// Different stacks logged per hang, at most.
    private static let stacksPerHang = 4

    /// Call on the main thread.
    public static func start() {
        let main = pthread_mach_thread_np(pthread_self())
        let thread = Thread { watch(main: main) }
        thread.name = "ZapFast hang monitor"
        thread.qualityOfService = .utility
        thread.start()
    }

    private static func watch(main: thread_t) {
        let log = Logger(subsystem: "ZapFast", category: "Hangs")
        let sampler = StackSampler(thread: main)
        while true {
            let answered = DispatchSemaphore(value: 0)
            let asked = DispatchTime.now()
            DispatchQueue.main.async { answered.signal() }
            if answered.wait(timeout: asked + limit) == .timedOut {
                var stacks: [[UInt]] = []
                repeat {
                    let stack = sampler.sample()
                    // The same stack again says nothing new.
                    if stacks.count < stacksPerHang, !stack.isEmpty, !stacks.contains(stack) {
                        stacks.append(stack)
                    }
                } while answered.wait(timeout: .now() + limit) == .timedOut
                let blocked = (DispatchTime.now().uptimeNanoseconds - asked.uptimeNanoseconds) / 1_000_000
                log.notice("Hang: the main thread did not answer for \(blocked, privacy: .public) ms")
                for (index, stack) in stacks.enumerated() {
                    let frames = StackSampler.describe(stack)
                    // A few frames a line, so no line is cut short.
                    for start in stride(from: 0, to: frames.count, by: 8) {
                        let line = frames[start..<min(start + 8, frames.count)].joined(separator: " ← ")
                        log.notice("Hang stack \(index + 1, privacy: .public) #\(start, privacy: .public): \(line, privacy: .public)")
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

/// Reads another thread's stack by its frame pointers while the thread is
/// suspended. Nothing in between allocates or takes a lock (the thread may
/// hold the allocator's): addresses go into a buffer made beforehand, and
/// memory is read with `vm_read_overwrite`, which fails instead of
/// faulting on a bad pointer.
nonisolated final class StackSampler {
    private let thread: thread_t
    private let buffer: UnsafeMutableBufferPointer<UInt>

    init(thread: thread_t) {
        self.thread = thread
        buffer = .allocate(capacity: 64)
        // The first Mach call of a thread sets up its reply port; done
        // here, not while the other thread is stopped.
        var word: UInt = 0
        var read: vm_size_t = 0
        withUnsafeMutablePointer(to: &word) { pointer in
            let address = vm_address_t(UInt(bitPattern: pointer))
            _ = vm_read_overwrite(mach_task_self_, address, vm_size_t(MemoryLayout<UInt>.size), address, &read)
        }
    }

    deinit {
        buffer.deallocate()
    }

    /// Code addresses from the innermost frame out; empty if the thread
    /// could not be read.
    func sample() -> [UInt] {
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        let count = walk()
        thread_resume(thread)
        return Array(buffer.prefix(count))
    }

    private func walk() -> Int {
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &stateCount)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        var count = 0
        buffer[count] = UInt(state.__pc) & Self.codeMask
        count += 1
        var frame = UInt(state.__fp)
        // Each frame record is the caller's frame pointer, then the return address.
        var record: (UInt, UInt) = (0, 0)
        while count < buffer.count, frame != 0, frame % 8 == 0 {
            var read: vm_size_t = 0
            let copied = withUnsafeMutablePointer(to: &record) { pointer in
                vm_read_overwrite(
                    mach_task_self_, vm_address_t(frame), vm_size_t(MemoryLayout<(UInt, UInt)>.size),
                    vm_address_t(UInt(bitPattern: pointer)), &read
                )
            }
            guard copied == KERN_SUCCESS else { break }
            let returnAddress = record.1 & Self.codeMask
            guard returnAddress != 0 else { break }
            buffer[count] = returnAddress
            count += 1
            // The stack grows down: callers' frames are higher.
            guard record.0 > frame else { break }
            frame = record.0
        }
        return count
        #else
        return 0
        #endif
    }

    /// Return addresses signed by pointer authentication carry the
    /// signature in their top bits.
    private static let codeMask: UInt = 0x0000_000F_FFFF_FFFF

    /// `image+0xoffset symbol` for each address; the offset is from the
    /// image's header, for `atos -o <image> -l 0 <offset>`.
    static func describe(_ stack: [UInt]) -> [String] {
        stack.map { address in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let base = info.dli_fbase else {
                return "0x" + String(address, radix: 16)
            }
            let image = info.dli_fname.map { String(cString: $0) }.map { ($0 as NSString).lastPathComponent } ?? "?"
            var text = "\(image)+0x\(String(address - UInt(bitPattern: base), radix: 16))"
            if let name = info.dli_sname {
                text += " " + String(String(cString: name).prefix(80))
            }
            return text
        }
    }
}
