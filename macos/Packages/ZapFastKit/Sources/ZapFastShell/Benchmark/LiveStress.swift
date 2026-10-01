import AppKit
import FeatureConversation
import OSLog
import ZapFastBridge
import ZapFastCore

/// `ZAPFAST_STRESS=<rounds>` drives the real window on the linked account as
/// a person would, and logs what each step cost, so a slowdown that builds
/// up over minutes shows as numbers (Console.app, subsystem ZapFast,
/// category Stress). Each round opens a chat, scrolls up through its history
/// as fast as a trackpad flick, and every fourth round resizes the window.
///
/// It opens only chats with nothing unread, so no message is marked read and
/// no read receipt leaves; it sends nothing and logs no chat names or text.
/// The app quits when it is done.
///
/// `ZAPFAST_STRESS_HOLD=<seconds>` keeps each chat at its top that long
/// after the flick, as someone waiting for older messages would, so the
/// phone is asked for history and its answer lands while the chat is open;
/// `ZAPFAST_STRESS_CHATS=<n>` takes that many chats (12 by default).
@MainActor
enum LiveStress {
    static var rounds: Int? {
        ProcessInfo.processInfo.environment["ZAPFAST_STRESS"].flatMap(Int.init)
    }

    private static let log = Logger(subsystem: "ZapFast", category: "Stress")

    static func start(model: AppModel, rounds: Int) {
        Task {
            await waitUntil { model.isLinked && !model.sidebarOrder.isEmpty && mainWindow() != nil }
            try? await Task.sleep(for: .seconds(2))
            let chats = model.sidebarOrder.filter { id in
                guard let chat = model.chats.chat(id) else { return false }
                return !chat.looksUnread && !chat.locked
            }.prefix(chatCount)
            log.notice("Stress: \(chats.count, privacy: .public) chats, \(rounds, privacy: .public) rounds")
            guard !chats.isEmpty, let window = mainWindow() else { return }
            let start = CACurrentMediaTime()
            for round in 0..<rounds {
                let chat = chats[chats.startIndex + round % chats.count]
                let open = await openChat(chat, model: model)
                let scroll = await flickUp()
                let held = hold > 0 ? await holdAtTop(seconds: hold) : (cpu: 0, gap: 0, rows: 0)
                let resize = round % 4 == 3 ? await resize(window) : 0
                log.notice("""
                    Stress: round \(round, privacy: .public) at \(Int(CACurrentMediaTime() - start), privacy: .public) s: \
                    open \(open.wall, privacy: .public) ms wall / \(open.cpu, privacy: .public) ms main, \
                    rows \(open.rows, privacy: .public)→\(scroll.rows, privacy: .public), \
                    scroll \(scroll.cpu, privacy: .public) ms main over \(scroll.wall, privacy: .public) ms, \
                    longest frame gap \(scroll.gap, privacy: .public) ms, resize \(resize, privacy: .public) ms main, \
                    held \(hold, privacy: .public) s: \(held.cpu, privacy: .public) ms main, longest gap \(held.gap, privacy: .public) ms, \
                    rows \(held.rows, privacy: .public), \
                    memory \(footprintMB(), privacy: .public) MB
                    """)
            }
            log.notice("Stress: done")
            NSApp.terminate(nil)
        }
    }

    private static var hold: Int {
        ProcessInfo.processInfo.environment["ZAPFAST_STRESS_HOLD"].flatMap(Int.init) ?? 0
    }

    private static var chatCount: Int {
        ProcessInfo.processInfo.environment["ZAPFAST_STRESS_CHATS"].flatMap(Int.init) ?? 12
    }

    // MARK: Steps

    /// At the top of the chat for `seconds`, nudged up again every tenth of
    /// a second as older pages push it down.
    private static func holdAtTop(seconds: Int) async -> (cpu: Int, gap: Int, rows: Int) {
        guard let table = timeline(), let scrollView = table.enclosingScrollView else { return (0, 0, 0) }
        let clip = scrollView.contentView
        let start = CACurrentMediaTime()
        let cpu = mainThreadCPU()
        var last = start
        var gap = 0.0
        while CACurrentMediaTime() - start < Double(seconds) {
            let now = CACurrentMediaTime()
            gap = max(gap, now - last)
            last = now
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: -clip.contentInsets.top))
            scrollView.reflectScrolledClipView(clip)
            try? await Task.sleep(for: .milliseconds(100))
        }
        return (Int(mainThreadCPU() - cpu), Int(gap * 1000), table.numberOfRows)
    }

    private static func openChat(_ chat: String, model: AppModel) async -> (wall: Int, cpu: Int, rows: Int) {
        let wall = CACurrentMediaTime()
        let cpu = mainThreadCPU()
        model.selectedChatID = chat
        let deadline = CACurrentMediaTime() + 3
        await waitUntil { (timeline()?.numberOfRows ?? 0) > 0 || CACurrentMediaTime() > deadline }
        let shown = Int((CACurrentMediaTime() - wall) * 1000)
        // What the open costs after the rows show: layouts, images, paging.
        try? await Task.sleep(for: .milliseconds(400))
        return (shown, Int(mainThreadCPU() - cpu), timeline()?.numberOfRows ?? 0)
    }

    /// Two seconds of scrolling up at 6,000 pt/s, a frame at a time, as
    /// older pages arrive; then a second of rest.
    private static func flickUp() async -> (wall: Int, cpu: Int, gap: Int, rows: Int) {
        guard let table = timeline(), let scrollView = table.enclosingScrollView else { return (0, 0, 0, 0) }
        let clip = scrollView.contentView
        let wall = CACurrentMediaTime()
        let cpu = mainThreadCPU()
        var last = CACurrentMediaTime()
        var gap = 0.0
        while CACurrentMediaTime() - wall < 2 {
            let now = CACurrentMediaTime()
            gap = max(gap, now - last)
            let step = 6_000 * (now - last)
            last = now
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(-clip.contentInsets.top, clip.bounds.minY - step)))
            scrollView.reflectScrolledClipView(clip)
            try? await Task.sleep(for: .milliseconds(8))
        }
        let spent = Int(mainThreadCPU() - cpu)
        try? await Task.sleep(for: .seconds(1))
        return (Int((CACurrentMediaTime() - wall) * 1000), spent, Int(gap * 1000), table.numberOfRows)
    }

    /// Narrower and back, in steps, as a drag would, then the frame it had.
    private static func resize(_ window: NSWindow) async -> Int {
        let original = window.frame
        let cpu = mainThreadCPU()
        for step in [-80.0, -160, -240, -160, -80, 0] {
            var frame = original
            frame.size.width += step
            window.setFrame(frame, display: true)
            try? await Task.sleep(for: .milliseconds(30))
        }
        window.setFrame(original, display: true)
        return Int(mainThreadCPU() - cpu)
    }

    // MARK: Helpers

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    private static func timeline() -> NSTableView? {
        guard let content = mainWindow()?.contentView else { return nil }
        return find(in: content)
    }

    private static func find(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, table.identifier == .messageTimeline { return table }
        for subview in view.subviews {
            if let found = find(in: subview) { return found }
        }
        return nil
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        while !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// CPU time the main thread has used, in milliseconds.
    private static func mainThreadCPU() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
    }

    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }
}
