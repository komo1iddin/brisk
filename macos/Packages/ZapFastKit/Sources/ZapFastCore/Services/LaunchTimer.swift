import Darwin
import Foundation
import OSLog

/// How long after the process started each step of launching took, logged
/// once per step. Seen in Console.app (subsystem ZapFast, category Launch) or
/// the Xcode console: comparing a run from Xcode with one opened from the
/// Finder separates the app's own launch from the debugger's.
@MainActor
final class LaunchTimer {
    private let log = Logger(subsystem: "ZapFast", category: "Launch")
    private let started = LaunchTimer.processStart() ?? Date()
    private var reached: Set<String> = []

    func step(_ name: StaticString) {
        let key = "\(name)"
        guard reached.insert(key).inserted else { return }
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        log.notice("Launch: \(key, privacy: .public) after \(milliseconds, privacy: .public) ms")
    }

    /// When the kernel started this process.
    private static func processStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let time = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }
}
