import AppKit
import FeatureConversation
import QuartzCore
import ZapFastBridge
import ZapFastCore

/// `--benchmark` runs the real window (sidebar, conversation, composer) on
/// made-up chats instead of the linked account, measures the message
/// timeline, prints a report and quits. `ZAPFAST_BENCHMARK_COUNT` sets how
/// many messages the fully loaded chat holds (default 2,000).
///
/// Build Release for numbers worth comparing:
/// `make release`, then run `ZapFast.app/Contents/MacOS/ZapFast --benchmark`.
enum TimelineBenchmark {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--benchmark")
    }

    private static var messageCount: Int {
        ProcessInfo.processInfo.environment["ZAPFAST_BENCHMARK_COUNT"].flatMap(Int.init) ?? 2_000
    }

    private static let backend = BenchmarkBackend(fullCount: messageCount, pagedCount: 5_000, chatCount: 200)

    /// A model on the made-up backend, with its own preferences (no app
    /// lock, no notifications) and folders apart from the real ones.
    static func makeModel() -> AppModel {
        let suite = "ZapFastBenchmark"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let preferences = Preferences(defaults: UserDefaults(suiteName: suite) ?? .standard)
        preferences.notifications = false
        let caches = AppPaths.standard().caches.appending(path: "Benchmark", directoryHint: .isDirectory)
        return AppModel(
            backend: backend,
            paths: AppPaths(data: caches.appending(path: "data"), caches: caches.appending(path: "cache")),
            preferences: preferences
        )
    }

    static func start(model: AppModel) {
        Task {
            let report = await BenchmarkRun(model: model, backend: backend).run()
            write(report, caches: AppPaths.standard().caches)
            NSApp.terminate(nil)
        }
    }

    /// Prints the report and keeps its JSON under Caches/benchmarks.
    private static func write(_ report: BenchmarkReport, caches: URL) {
        print(report.summary)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        let directory = caches.appending(path: "benchmarks", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "timeline-\(Int(Date.now.timeIntervalSince1970)).json")
        try? data.write(to: file)
        print("BENCHMARK_JSON \(file.path(percentEncoded: false))")
        fflush(stdout)
    }
}

/// One pass through every scenario, in order, on the main actor.
private final class BenchmarkRun: NSObject {
    private let model: AppModel
    private let backend: BenchmarkBackend
    private var window: NSWindow!

    init(model: AppModel, backend: BenchmarkBackend) {
        self.model = model
        self.backend = backend
    }

    func run() async -> BenchmarkReport {
        model.start()
        await waitUntil { self.model.isLinked && self.mainWindow() != nil }
        window = mainWindow()
        window.setFrame(NSRect(x: 60, y: 60, width: 1100, height: 740), display: true)
        await pause(.milliseconds(500))

        let paged = backend.history(SyntheticChats.pagedChat)
        let openFirstPage = await open(
            SyntheticChats.pagedChat,
            rows: TimelineRow.build(Array(paged.suffix(BenchmarkBackend.page))).count
        )
        let eventsWithFirstPage = await eventCosts()
        let pagingScroll = await scroll(speed: 5_000, duration: 8)

        let full = backend.history(SyntheticChats.fullChat)
        let openFullHistory = await open(SyntheticChats.fullChat, rows: TimelineRow.build(full).count)
        await pause(.milliseconds(300))
        let timelineWidth = timeline?.bounds.width ?? 0
        let fullScroll = await scroll(speed: 5_000, duration: 8)
        let jumps = measureJumps()
        let eventsWithFullHistory = await eventCosts()
        let resize = measureResize()

        let small = backend.history(SyntheticChats.smallChat)
        let openWarm = await open(SyntheticChats.smallChat, rows: TimelineRow.build(small).count)

        return BenchmarkReport(
            messageCount: full.count,
            machine: Self.machine,
            system: ProcessInfo.processInfo.operatingSystemVersionString,
            configuration: Self.configuration,
            windowSize: "\(Int(window.frame.width))×\(Int(window.frame.height))",
            timelineWidth: timelineWidth,
            openFirstPage: openFirstPage,
            eventsWithFirstPage: eventsWithFirstPage,
            pagingScroll: pagingScroll,
            openFullHistory: openFullHistory,
            fullScroll: fullScroll,
            jumpToOffsetMs: .init(jumps),
            eventsWithFullHistory: eventsWithFullHistory,
            resizeStepMs: .init(resize),
            openFirstPageWarm: openWarm,
            memoryFootprintMB: Self.memoryFootprintMB
        )
    }

    // MARK: Opening

    private func open(_ chat: String, rows: Int) async -> BenchmarkReport.Open {
        let wall = CACurrentMediaTime()
        let cpu = Self.mainThreadCPU()
        model.selectedChatID = chat
        await waitUntil { self.timeline?.numberOfRows == rows }
        window.displayIfNeeded()
        CATransaction.flush()
        return .init(
            rows: rows,
            wallMs: (CACurrentMediaTime() - wall) * 1000,
            mainThreadMs: Self.mainThreadCPU() - cpu
        )
    }

    // MARK: Scrolling

    private var link: CADisplayLink?
    private var continuation: CheckedContinuation<Void, Never>?
    private var speed = 0.0
    private var duration = 0.0
    private var lastTimestamp: CFTimeInterval = 0
    private var elapsed = 0.0
    private var atTop = 0.0
    private var intervals: [Double] = []
    private var budgets: [Double] = []
    private var work: [Double] = []

    /// Scrolls up from where the timeline is, one step per display frame.
    /// Older pages arrive as they do in use: the timeline asks near the top
    /// and the backend answers on a later turn.
    private func scroll(speed: Double, duration: Double) async -> BenchmarkReport.Scroll {
        self.speed = speed
        self.duration = duration
        lastTimestamp = 0
        elapsed = 0
        atTop = 0
        intervals = []
        budgets = []
        work = []
        let rowsAtStart = timeline?.numberOfRows ?? 0
        let pagesAtStart = backend.pagesServed

        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let link = window.contentView!.displayLink(target: self, selector: #selector(step(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        await pause(.milliseconds(300))

        let budget = budgets.isEmpty ? 1.0 / 60 : budgets.reduce(0, +) / Double(budgets.count)
        var hitches = 0
        var hitchTime = 0.0
        for (interval, frameBudget) in zip(intervals, budgets) where interval > frameBudget * 1.5 {
            hitches += 1
            hitchTime += interval - frameBudget
        }
        return .init(
            rowsAtStart: rowsAtStart,
            rowsAtEnd: timeline?.numberOfRows ?? 0,
            olderPagesLoaded: backend.pagesServed - pagesAtStart,
            speedPointsPerSecond: speed,
            durationSeconds: elapsed,
            secondsAtTop: atTop,
            frames: intervals.count,
            frameBudgetMs: budget * 1000,
            frameWorkMs: .init(work.map { $0 * 1000 }),
            frameIntervalMs: .init(intervals.map { $0 * 1000 }),
            hitches: hitches,
            hitchTimeRatioMsPerSecond: elapsed > 0 ? hitchTime * 1000 / elapsed : 0
        )
    }

    @objc private func step(_ link: CADisplayLink) {
        let frameBudget = link.targetTimestamp - link.timestamp
        let delta: Double
        if lastTimestamp > 0 {
            delta = link.timestamp - lastTimestamp
            intervals.append(delta)
            budgets.append(frameBudget)
            elapsed += delta
        } else {
            delta = frameBudget
        }
        lastTimestamp = link.timestamp

        guard let table = timeline, let scrollView = table.enclosingScrollView else { return }
        let start = CACurrentMediaTime()
        let clip = scrollView.contentView
        let top = -clip.contentInsets.top
        let y = max(clip.bounds.origin.y - speed * delta, top)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
        table.layoutSubtreeIfNeeded()
        scrollView.displayIfNeeded()
        // Layer contents are drawn at commit time; flush so they count toward this frame.
        CATransaction.flush()
        work.append(CACurrentMediaTime() - start)
        if y <= top { atTop += delta }

        let conversation = model.conversations.conversation(model.selectedChatID ?? "")
        let exhausted = conversation.complete && !conversation.loadingOlder
        if elapsed >= duration || (y <= top && exhausted) {
            link.invalidate()
            self.link = nil
            continuation?.resume()
            continuation = nil
        }
    }

    /// Time to show a far-away position, like dragging the scroller thumb.
    private func measureJumps() -> [Double] {
        guard let table = timeline, let scrollView = table.enclosingScrollView else { return [] }
        var generator = SplitMix64(seed: 7)
        let clip = scrollView.contentView
        let maxY = max(table.frame.height - clip.bounds.height, 0)
        return (0..<40).map { _ in
            let target = Double(generator.next() % 10_000) / 10_000 * maxY
            let start = CACurrentMediaTime()
            clip.scroll(to: NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(clip)
            table.layoutSubtreeIfNeeded()
            scrollView.displayIfNeeded()
            CATransaction.flush()
            return (CACurrentMediaTime() - start) * 1000
        }
    }

    // MARK: Events elsewhere

    /// What the open chat pays for things that happen in another one: a
    /// contact coming online, and a message arriving there. Each sample is
    /// the main thread's CPU time from the event until the window has had
    /// time to update, less the same wait with no event.
    private func eventCosts() async -> BenchmarkReport.EventCost {
        let samples = 15
        let settle = Duration.milliseconds(80)
        func sample(_ event: () -> Void) async -> Double {
            let cpu = Self.mainThreadCPU()
            event()
            await pause(settle)
            return Self.mainThreadCPU() - cpu
        }

        await pause(.milliseconds(300))
        var idle: [Double] = []
        for _ in 0..<samples { idle.append(await sample {}) }
        let baseline = BenchmarkReport.Distribution(idle).p50

        var presence: [Double] = []
        for index in 0..<samples {
            presence.append(await sample {
                backend.inject([.presence(id: SyntheticChats.otherChat, online: index.isMultiple(of: 2), lastSeen: nil)])
            } - baseline)
        }

        var messages: [Double] = []
        let newest = backend.history(SyntheticChats.fullChat).last?.timestamp ?? 0
        for index in 0..<samples {
            let timestamp = newest + Int64(index + 1)
            let message = SyntheticChats.message(
                chat: SyntheticChats.otherChat, id: "elsewhere-\(eventRound)-\(index)",
                sender: SyntheticChats.otherChat, senderName: nil, fromMe: false,
                timestamp: timestamp, text: "Salom!"
            )
            let chat = SyntheticChats.chat(
                id: SyntheticChats.otherChat, name: "Other chat", kind: .direct,
                activity: timestamp, unread: UInt32(index + 1)
            )
            // What the worker sends for a message in a chat that is not open.
            messages.append(await sample {
                backend.inject([
                    .messages(chat: SyntheticChats.otherChat, messages: [message], older: false, complete: false),
                    .chatUpdated(chat: chat),
                    .incoming(chat: SyntheticChats.otherChat, message: message),
                ])
            } - baseline)
        }
        eventRound += 1

        return .init(
            rows: timeline?.numberOfRows ?? 0,
            baselineMs: baseline,
            presenceElsewhereMs: .init(presence),
            messageElsewhereMs: .init(messages)
        )
    }

    private var eventRound = 0

    // MARK: Resizing

    /// Narrows the window 8 points at a time, as a resize drag does, and
    /// times each step through layout, drawing and the commit.
    private func measureResize() -> [Double] {
        let original = window.frame
        let steps = (1...10).map { index in
            let start = CACurrentMediaTime()
            var frame = original
            frame.size.width -= CGFloat(index * 8)
            window.setFrame(frame, display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            return (CACurrentMediaTime() - start) * 1000
        }
        window.setFrame(original, display: true)
        return steps
    }

    // MARK: Helpers

    /// The open chat's message table.
    private var timeline: NSTableView? {
        window?.contentView.flatMap(Self.findTimeline)
    }

    private static func findTimeline(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, table.identifier == .messageTimeline { return table }
        for subview in view.subviews {
            if let table = findTimeline(in: subview) { return table }
        }
        return nil
    }

    private func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        while !condition() {
            await pause(.milliseconds(1))
        }
    }

    private func pause(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }

    /// CPU time the calling (main) thread has used, in milliseconds.
    private static func mainThreadCPU() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
    }

    private static var configuration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    private static var machine: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static var memoryFootprintMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
