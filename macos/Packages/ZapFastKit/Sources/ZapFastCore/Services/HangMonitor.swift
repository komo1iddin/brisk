import Foundation
import OSLog

/// Logs each time the main thread stops answering for a quarter of a
/// second or more, and for how long (subsystem ZapFast, category Hangs),
/// so a freeze someone saw can be found in the log afterwards next to the
/// events that were arriving (category Events). Only durations are logged.
///
/// A thread of its own asks the main queue to answer every tenth of a
/// second; an answer that has not come within the limit is a hang, timed
/// until it comes.
public nonisolated enum HangMonitor {
    private static let limit = DispatchTimeInterval.milliseconds(250)

    public static func start() {
        let thread = Thread { watch() }
        thread.name = "ZapFast hang monitor"
        thread.qualityOfService = .utility
        thread.start()
    }

    private static func watch() {
        let log = Logger(subsystem: "ZapFast", category: "Hangs")
        while true {
            let answered = DispatchSemaphore(value: 0)
            let asked = DispatchTime.now()
            DispatchQueue.main.async { answered.signal() }
            if answered.wait(timeout: asked + limit) == .timedOut {
                answered.wait()
                let blocked = (DispatchTime.now().uptimeNanoseconds - asked.uptimeNanoseconds) / 1_000_000
                log.notice("Hang: the main thread did not answer for \(blocked, privacy: .public) ms")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
