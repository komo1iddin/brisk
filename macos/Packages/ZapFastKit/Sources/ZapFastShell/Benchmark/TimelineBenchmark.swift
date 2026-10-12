import AppKit
import FeatureConversation
import OSLog
import QuartzCore
import ZapFastBridge
import ZapFastCore

/// `--benchmark` runs the real window (sidebar, conversation, composer) on
/// made-up chats instead of the linked account, measures the message
/// timeline, prints a report and quits. `ZAPFAST_BENCHMARK_COUNT` sets how
/// many messages the source fixture holds (default 2,000). The active
/// pane retains only its budgeted window of that history.
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

    /// `ZAPFAST_BENCHMARK_MEDIA=0` leaves the chats text alone, as the
    /// benchmark's first runs were.
    private static var withMedia: Bool {
        ProcessInfo.processInfo.environment["ZAPFAST_BENCHMARK_MEDIA"] != "0"
    }

    static let backend = BenchmarkBackend(
        fullCount: messageCount, pagedCount: 5_000, chatCount: 200,
        media: withMedia ? SyntheticMedia(directory: AppPaths.standard().caches.appending(path: "Benchmark/media")) : nil
    )

    /// A model on the made-up backend, with its own preferences (no app
    /// lock, no notifications) and folders apart from the real ones.
    static func makeModel() -> AppModel {
        let suite = "ZapFastBenchmark"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let preferences = Preferences(defaults: defaults)
        let accountPreferences = AccountPreferences(defaults: defaults)
        accountPreferences.notifications = false
        let caches = AppPaths.standard().caches.appending(path: "Benchmark", directoryHint: .isDirectory)
        return AppModel(
            backend: backend,
            paths: AppPaths(data: caches.appending(path: "data"), caches: caches.appending(path: "cache")),
            preferences: preferences,
            accountPreferences: accountPreferences
        )
    }

    static func start(model: AppModel) {
        Task {
            // Time to attach Instruments: `ZAPFAST_BENCHMARK_DELAY=<seconds>`.
            if let delay = ProcessInfo.processInfo.environment["ZAPFAST_BENCHMARK_DELAY"].flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(delay))
            }
            let report = await BenchmarkRun(model: model, backend: backend).run()
            write(report, caches: AppPaths.standard().caches)
            // `ZAPFAST_BENCHMARK_KEEP=1` leaves the made-up chats on screen,
            // to look at the window without real ones.
            if ProcessInfo.processInfo.environment["ZAPFAST_BENCHMARK_KEEP"] == nil { NSApp.terminate(nil) }
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
    private var windowActivity: [String: BenchmarkReport.WindowActivity] = [:]
    private var resizeBatchMainThreadMs = 0.0
    private var resizeBatchProcessCPUms = 0.0
    private var resizeSamples: [BenchmarkReport.ResizeSample] = []
    private let resizeScenario = ResizeScenario(requestedRounds: ProcessInfo.processInfo.environment["ZAPFAST_BENCHMARK_RESIZE_ROUNDS"])
    private weak var cachedTimeline: NSTableView?
    private let resizeHoldMs = max(0, ProcessInfo.processInfo.environment["ZAPFAST_BENCHMARK_RESIZE_HOLD_MS"].flatMap(Double.init) ?? 0)

    init(model: AppModel, backend: BenchmarkBackend) {
        self.model = model
        self.backend = backend
    }

    func run() async -> BenchmarkReport {
        model.start()
        await waitUntil { self.model.isLinked && self.mainWindow() != nil }
        window = mainWindow()
        // A subprocess can inherit a different Space from the front app.
        // Keep ordinary timings at the normal level, on the active Space.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        if ProcessInfo.processInfo.environment["ZAPFAST_BENCHMARK_FLOATING"] == "1" {
            // Diagnostic profiling on a desktop covered by another app.
            // This mode is excluded from ordinary A/B timings.
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.level = .floating
            window.orderFrontRegardless()
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
        let width = ProcessInfo.processInfo.environment["ZAPFAST_BENCHMARK_WINDOW_WIDTH"].flatMap(Double.init) ?? 1100
        window.setFrame(NSRect(x: 60, y: 60, width: width, height: 740), display: true)
        // A pointer resting on the window makes hover views in the rows it
        // crosses, which varied results from run to run; runs leave it out
        // unless `ZAPFAST_BENCHMARK_POINTER=1`. `=over` puts the window
        // where the pointer rests on the middle of the timeline, as when
        // scrolling with a trackpad.
        switch ProcessInfo.processInfo.environment["ZAPFAST_BENCHMARK_POINTER"] {
        case nil:
            window.ignoresMouseEvents = true
        case "over":
            let pointer = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: pointer.x - 700, y: pointer.y - 370))
        default:
            break
        }
        await pause(.milliseconds(500))

        let paged = backend.history(SyntheticChats.pagedChat)
        let openFirstPage = await open(
            SyntheticChats.pagedChat,
            rows: TimelineRow.build(Array(paged.suffix(BenchmarkBackend.page))).count
        )
        let eventsWithFirstPage = await eventCosts(open: SyntheticChats.pagedChat, name: "Benchmark (paged)")
        let pagingScroll = await measured("PagedScroll") { await self.scroll(speed: 5_000, duration: 8) }
        let pagingFlicks = await measured("PagedFlicks") { await self.flicks() }

        let full = backend.history(SyntheticChats.fullChat)
        let resident = full.count > HistoryBudget.standard.rows ? full.suffix(HistoryBudget.standard.rows * 3 / 4) : full[...]
        let openFullHistory = await open(SyntheticChats.fullChat, rows: TimelineRow.build(resident).count)
        await pause(.milliseconds(300))
        let timelineWidth = timeline?.bounds.width ?? 0
        let fullScroll = await measured("FullScroll") { await self.scroll(speed: 5_000, duration: 8) }
        let fullFlicks = await measured("FullFlicks") { await self.flicks() }
        let jumps = measureJumps()
        // Paging can leave a bounded pane in an old archive window. Reopen
        // from the retained newest cache before measuring live arrivals, so
        // the Here samples exercise visible row updates rather than ignored
        // out-of-window deliveries. Setup is outside the measured samples.
        model.selectedChatID = nil
        await pause(.milliseconds(50))
        let warmRows = TimelineRow.build(model.conversations.conversation(SyntheticChats.fullChat).messages).count
        _ = await open(SyntheticChats.fullChat, rows: warmRows)
        let eventsWithFullHistory = await eventCosts(open: SyntheticChats.fullChat, name: "Benchmark (full)")
        let activeFootprint = Self.memoryFootprintMB
        let retained = model.conversations.conversation(SyntheticChats.fullChat)
        let resize = await measureResize()

        let small = backend.history(SyntheticChats.smallChat)
        let openWarm = await open(SyntheticChats.smallChat, rows: TimelineRow.build(small).count)
        let sidebarScroll = await measured("SidebarScroll") { await self.scrollSidebar() }

        return BenchmarkReport(
            messageCount: full.count,
            residentMessages: retained.messages.count,
            retainedRecordBytes: retained.retainedBytes,
            activeChatFootprintMB: activeFootprint,
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
            resizeHoldMs: resizeHoldMs,
            openFirstPageWarm: openWarm,
            memoryFootprintMB: Self.memoryFootprintMB,
            pagingFlicks: pagingFlicks,
            fullFlicks: fullFlicks,
            sidebarScroll: sidebarScroll,
            integrity: integrity,
            windowActivity: windowActivity,
            resizeBatchMainThreadMs: resizeBatchMainThreadMs,
            resizeBatchProcessCPUms: resizeBatchProcessCPUms,
            resizeSamples: resizeSamples,
            resizeRounds: resizeScenario.rounds
        )
    }

    // MARK: Opening

    private func measured(_ phase: StaticString, _ operation: () async -> BenchmarkReport.Scroll) async -> BenchmarkReport.Scroll {
        let interval = Self.signposter.beginInterval(phase)
        defer { Self.signposter.endInterval(phase, interval) }
        return await operation()
    }

    private func open(_ chat: String, rows: Int) async -> BenchmarkReport.Open {
        let interval = Self.signposter.beginInterval("Open")
        defer { Self.signposter.endInterval("Open", interval) }
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
    /// The direction at a moment of the run: -1 scrolls up, 1 down.
    private var direction: (Double) -> Double = { _ in -1 }
    private var duration = 0.0
    private var lastTimestamp: CFTimeInterval = 0
    private var elapsed = 0.0
    private var atTop = 0.0
    private var intervals: [Double] = []
    private var budgets: [Double] = []
    private var work: [Double] = []
    private var stopsAtTop = true
    /// Scrolled instead of the timeline, when set: the chat list.
    private var scrolled: NSTableView?

    /// The chat list, down and back up at 3,000 pt/s, as a person looks
    /// for a chat.
    private func scrollSidebar() async -> BenchmarkReport.Scroll {
        scrolled = window.contentView.flatMap(Self.findSidebar)
        stopsAtTop = false
        defer {
            scrolled = nil
            stopsAtTop = true
        }
        return await scroll(speed: 3_000, duration: 4) { elapsed in elapsed < 2 ? 1 : -1 }
    }

    private static func findSidebar(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, table.accessibilityLabel() == String(localized: "Chats") { return table }
        for subview in view.subviews {
            if let table = findSidebar(in: subview) { return table }
        }
        return nil
    }
    /// Each step is a "Frame" interval in Points of Interest, for tracing
    /// what the main thread does in slow frames and between them.
    private static let signposter = OSSignposter(subsystem: "ZapFast", category: .pointsOfInterest)
    private var integrity = BenchmarkReport.Integrity()

    /// Up fast, then back down fast, three times, as a trackpad flick and
    /// its return: the moment the reader saw the timeline go blank.
    private func flicks() async -> BenchmarkReport.Scroll {
        stopsAtTop = false
        defer { stopsAtTop = true }
        return await scroll(speed: 7_000, duration: 4.2) { elapsed in
            elapsed.truncatingRemainder(dividingBy: 1.4) < 0.7 ? -1 : 1
        }
    }

    /// Visible rows whose row view, cell or the cell's parts are not where
    /// the table put them, are hidden, or have no view at all.
    private func audit(_ table: NSTableView) -> BenchmarkReport.Integrity.Sample {
        guard let clip = table.enclosingScrollView?.contentView else { return .init() }
        let visible = table.rows(in: clip.documentVisibleRect)
        var sample = BenchmarkReport.Integrity.Sample()
        guard visible.location != NSNotFound, visible.length > 0 else { return sample }
        func close(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
                && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
        }
        for row in visible.location..<min(NSMaxRange(visible), table.numberOfRows) {
            sample.rows += 1
            guard let rowView = table.rowView(atRow: row, makeIfNecessary: false) else {
                sample.missing += 1
                continue
            }
            var problems: [String] = []
            if !close(rowView.frame, table.rect(ofRow: row)) { problems.append("row frame") }
            if rowView.isHidden { problems.append("row hidden") }
            if let layer = rowView.layer, !close(CGRect(origin: .zero, size: layer.bounds.size), CGRect(origin: .zero, size: rowView.frame.size)) {
                problems.append("row layer")
            }
            if let cell = rowView.view(atColumn: 0) as? NSView {
                if cell.isHidden || cell.alphaValue < 0.01 { problems.append("cell hidden") }
                if abs(cell.frame.height - rowView.bounds.height) > 0.5 || cell.frame.width < 1 || abs(cell.frame.minY) > 0.5 {
                    problems.append("cell frame")
                }
                if let layer = cell.layer, abs(layer.bounds.height - cell.frame.height) > 0.5 { problems.append("cell layer") }
                for part in cell.subviews where !part.isHidden && part.alphaValue > 0.01 {
                    if part.frame.width < 1 || part.frame.height < 1 { problems.append("part empty \(type(of: part))") }
                    if let layer = part.layer, abs(layer.bounds.width - part.frame.width) > 0.5 {
                        problems.append("part layer \(type(of: part))")
                    }
                }
            } else {
                problems.append("no cell")
            }
            if !problems.isEmpty {
                sample.misplaced += 1
                for problem in problems { sample.kinds[problem, default: 0] += 1 }
            }
        }
        return sample
    }

    /// Scrolls up from where the timeline is (or as `direction` says), one
    /// step per display frame. Older pages arrive as they do in use: the
    /// timeline asks near the top and the backend answers on a later turn.
    private func scroll(
        speed: Double,
        duration: Double,
        direction: @escaping (Double) -> Double = { _ in -1 }
    ) async -> BenchmarkReport.Scroll {
        print("BENCHMARK_SCROLL_START rows=\(timeline?.numberOfRows ?? -1) visible=\(window.occlusionState.contains(.visible)) screen=\(window.screen != nil)")
        fflush(stdout)
        self.speed = speed
        self.direction = direction
        self.duration = duration
        lastTimestamp = 0
        elapsed = 0
        atTop = 0
        intervals = []
        budgets = []
        work = []
        let rowsAtStart = timeline?.numberOfRows ?? 0
        let pagesAtStart = backend.pagesServed
        let mainCPU = Self.mainThreadCPU()
        let processCPU = Self.processCPU()

        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let link = window.contentView!.displayLink(target: self, selector: #selector(step(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        let mainThreadMs = Self.mainThreadCPU() - mainCPU
        let processCPUms = Self.processCPU() - processCPU
        await pause(.milliseconds(300))
        if let table = timeline { integrity.add(audit(table), at: .rest) }

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
            hitchTimeRatioMsPerSecond: elapsed > 0 ? hitchTime * 1000 / elapsed : 0,
            mainThreadMs: mainThreadMs,
            processCPUms: processCPUms
        )
    }

    @objc private func step(_ link: CADisplayLink) {
        checkWindow("Scroll")
        let frameBudget = link.targetTimestamp - link.timestamp
        let delta: Double
        if lastTimestamp > 0 {
            delta = link.timestamp - lastTimestamp
            intervals.append(delta)
            budgets.append(frameBudget)
            elapsed += delta
        } else {
            print("BENCHMARK_SCROLL_FIRST_FRAME rows=\(timeline?.numberOfRows ?? -1)")
            fflush(stdout)
            delta = frameBudget
        }
        lastTimestamp = link.timestamp

        guard let table = scrolled ?? timeline, let scrollView = table.enclosingScrollView else { return }
        // What AppKit's own passes left on screen since the last frame.
        if scrolled == nil { integrity.add(audit(table), at: .beforeFrame) }
        let frame = Self.signposter.beginInterval("Frame")
        defer { Self.signposter.endInterval("Frame", frame) }
        let start = CACurrentMediaTime()
        let clip = scrollView.contentView
        let top = -clip.contentInsets.top
        let bottom = max(top, table.frame.height - clip.bounds.height + clip.contentInsets.bottom)
        let y = min(max(clip.bounds.origin.y + direction(elapsed) * speed * delta, top), bottom)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
        table.layoutSubtreeIfNeeded()
        scrollView.displayIfNeeded()
        // Layer contents are drawn at commit time; flush so they count toward this frame.
        CATransaction.flush()
        work.append(CACurrentMediaTime() - start)
        if scrolled == nil { integrity.add(audit(table), at: .afterFrame) }
        if y <= top { atTop += delta }

        let conversation = model.conversations.conversation(model.selectedChatID ?? "")
        let exhausted = conversation.complete && !conversation.loadingOlder
        if elapsed >= duration || (y <= top && exhausted && direction(elapsed) < 0 && stopsAtTop) {
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
    /// contact coming online, and a message arriving there; then for a
    /// message arriving in the open chat itself. Each sample is the main
    /// thread's CPU time from the event until the window has had time to
    /// update, less the same wait with no event.
    private func eventCosts(open: String, name: String) async -> BenchmarkReport.EventCost {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        let samples = 15
        let settle = Duration.milliseconds(80)
        // Each sample is a signpost, to find it in a trace.
        func sample(_ name: StaticString = "Event", _ event: () -> Void) async -> Double {
            let phase = "Events.\(eventRound).\(name)"
            checkWindow(phase)
            let interval = Self.signposter.beginInterval(name)
            let cpu = Self.mainThreadCPU()
            event()
            await pause(settle)
            Self.signposter.endInterval(name, interval)
            let cost = Self.mainThreadCPU() - cpu
            checkWindow(phase)
            return cost
        }

        await pause(.milliseconds(300))
        var idle: [Double] = []
        for _ in 0..<samples { idle.append(await sample("Idle") {}) }
        let baseline = BenchmarkReport.Distribution(idle).p50

        var presence: [Double] = []
        for index in 0..<samples {
            presence.append(await sample("Presence") {
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
            messages.append(await sample("Elsewhere") {
                backend.inject([
                    .messages(chat: SyntheticChats.otherChat, messages: [message], older: false, complete: false),
                    .chatUpdated(chat: chat),
                    .incoming(chat: SyntheticChats.otherChat, message: message),
                ])
            } - baseline)
        }
        let rows = timeline?.numberOfRows ?? 0

        // A member writes in the open chat, read at once (the reader is at
        // the bottom).
        var here: [Double] = []
        let last = model.conversations.conversation(open).messages.last?.timestamp ?? newest
        for index in 0..<samples {
            let timestamp = max(last, newest + Int64(samples)) + Int64(index + 1)
            let message = SyntheticChats.message(
                chat: open, id: "here-\(eventRound)-\(index)",
                sender: "998900000001@s.whatsapp.net", senderName: "Dilnoza", fromMe: false,
                timestamp: timestamp, text: "Ok 👍"
            )
            let chat = SyntheticChats.chat(id: open, name: name, kind: .group, activity: timestamp)
            here.append(await sample("Here") {
                backend.inject([
                    .messages(chat: open, messages: [message], older: false, complete: false),
                    .chatUpdated(chat: chat),
                    .incoming(chat: open, message: message),
                ])
            } - baseline)
        }
        eventRound += 1

        return .init(
            rows: rows,
            baselineMs: baseline,
            presenceElsewhereMs: .init(presence),
            messageElsewhereMs: .init(messages),
            messageHereMs: .init(here)
        )
    }

    private var eventRound = 0

    // MARK: Resizing

    /// Narrows the window 8 points at a time, as a resize drag does, and
    /// times each step through layout, drawing and the commit.
    private func measureResize() async -> [Double] {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Measure resize after the last arrival's spring has finished.
        // Both builds use the same settling time outside timed intervals.
        await pause(.milliseconds(500))
        let burst = Self.signposter.beginInterval("ResizeBurst")
        let mainCPU = Self.mainThreadCPU()
        let processCPU = Self.processCPU()
        defer {
            resizeBatchMainThreadMs = Self.mainThreadCPU() - mainCPU
            resizeBatchProcessCPUms = Self.processCPU() - processCPU
            Self.signposter.endInterval("ResizeBurst", burst)
        }
        let original = window.frame
        var steps: [Double] = []
        for round in 1...resizeScenario.rounds {
            for index in 1...ResizeScenario.steps {
                checkWindow("Resize")
                let interval = Self.signposter.beginInterval("ResizeStep")
                let start = CACurrentMediaTime()
                let stepMainCPU = Self.mainThreadCPU()
                let stepProcessCPU = Self.processCPU()
                var frame = original
                frame.size.width -= CGFloat(index * ResizeScenario.pointsPerStep)
                window.setFrame(frame, display: true)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
                let wallMs = (CACurrentMediaTime() - start) * 1000
                resizeSamples.append(.init(round: round, step: index, windowWidth: frame.width, wallMs: wallMs,
                                           mainThreadMs: Self.mainThreadCPU() - stepMainCPU,
                                           processCPUms: Self.processCPU() - stepProcessCPU))
                steps.append(wallMs)
                Self.signposter.endInterval("ResizeStep", interval)
                checkWindow("Resize")
                if let table = timeline { integrity.add(audit(table), at: .resize) }
                // A turn of the run loop, as between the frames of a drag.
                await pause(.milliseconds(16))
                if let table = timeline { integrity.add(audit(table), at: .resize) }
            }
            // A held final width must finish its useful reflow, unlike a burst
            // that immediately returns to the already-measured original width.
            if resizeHoldMs > 0 {
                await pause(.seconds(resizeHoldMs / 1000))
                checkWindow("ResizeHold")
                if let table = timeline { integrity.add(audit(table), at: .rest) }
            }
            window.setFrame(original, display: true)
            await pause(.milliseconds(100))
            if let table = timeline { integrity.add(audit(table), at: .rest) }
        }
        return steps
    }

    // MARK: Helpers

    private func checkWindow(_ phase: String) {
        var state = windowActivity[phase] ?? .init()
        state.checks += 1
        if !NSApp.isActive { state.inactive += 1 }
        if !window.occlusionState.contains(.visible) { state.occluded += 1 }
        let thermal = String(ProcessInfo.processInfo.thermalState.rawValue)
        state.thermalStates[thermal, default: 0] += 1
        windowActivity[phase] = state
    }

    /// The open chat's message table.
    private var timeline: NSTableView? {
        if let cachedTimeline, cachedTimeline.window === window { return cachedTimeline }
        cachedTimeline = window?.contentView.flatMap(Self.findTimeline)
        return cachedTimeline
    }

    private static func processCPU() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)) / 1_000_000
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
