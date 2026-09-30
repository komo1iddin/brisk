import Foundation

/// What one benchmark run measured. Times are milliseconds.
nonisolated struct BenchmarkReport: Codable, Sendable {
    struct Distribution: Codable, Sendable {
        var p50: Double
        var p95: Double
        var p99: Double
        var max: Double

        init(_ samples: [Double]) {
            let sorted = samples.sorted()
            func percentile(_ p: Double) -> Double {
                guard !sorted.isEmpty else { return 0 }
                return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
            }
            p50 = percentile(0.5)
            p95 = percentile(0.95)
            p99 = percentile(0.99)
            max = sorted.last ?? 0
        }
    }

    /// Opening a chat: from selecting it until its rows are on screen.
    struct Open: Codable, Sendable {
        var rows: Int
        var wallMs: Double
        /// Main-thread CPU time spent over the same span.
        var mainThreadMs: Double
    }

    /// Scrolling up at a fixed speed, one step per display frame.
    struct Scroll: Codable, Sendable {
        var rowsAtStart: Int
        var rowsAtEnd: Int
        var olderPagesLoaded: Int
        var speedPointsPerSecond: Double
        var durationSeconds: Double
        /// Time spent at the top edge with nothing more arriving: older pages
        /// that were not asked for, or not placed above the reader.
        var secondsAtTop: Double
        var frames: Int
        var frameBudgetMs: Double
        /// Main-thread time per frame for scrolling, cell layout, drawing and
        /// the Core Animation commit.
        var frameWorkMs: Distribution
        var frameIntervalMs: Distribution
        var hitches: Int
        /// Apple's hitch metric: milliseconds of hitch per second of scrolling.
        /// Under 5 is "good", over 10 is "bad".
        var hitchTimeRatioMsPerSecond: Double
    }

    /// Main-thread CPU time an event costs, less an idle baseline.
    struct EventCost: Codable, Sendable {
        var rows: Int
        var baselineMs: Double
        var presenceElsewhereMs: Distribution
        var messageElsewhereMs: Distribution
    }

    /// Rows on screen that were not drawn where the table put them: the
    /// timeline going blank or flickering. Counted every frame of every
    /// scroll (before AppKit's frame and after ours), after each resize step
    /// and once things rest. Any at all is a bug.
    struct Integrity: Codable, Sendable {
        enum Moment: String, Codable, Sendable { case beforeFrame, afterFrame, resize, rest }

        struct Sample: Codable, Sendable {
            var rows = 0
            var misplaced = 0
            var missing = 0
            var kinds: [String: Int] = [:]
        }

        var checks = 0
        var rows = 0
        /// Checks that found at least one row wrong or missing, by moment.
        var badChecks: [String: Int] = [:]
        var misplacedRows = 0
        var missingRows = 0
        var kinds: [String: Int] = [:]

        mutating func add(_ sample: Sample, at moment: Moment) {
            checks += 1
            rows += sample.rows
            misplacedRows += sample.misplaced
            missingRows += sample.missing
            if sample.misplaced + sample.missing > 0 { badChecks[moment.rawValue, default: 0] += 1 }
            for (kind, count) in sample.kinds { kinds[kind, default: 0] += count }
        }
    }

    var messageCount: Int
    var machine: String
    var system: String
    var configuration: String
    var windowSize: String
    var timelineWidth: Double
    var openFirstPage: Open
    var eventsWithFirstPage: EventCost
    var pagingScroll: Scroll
    var openFullHistory: Open
    var fullScroll: Scroll
    var jumpToOffsetMs: Distribution
    var eventsWithFullHistory: EventCost
    /// One window-width step of 8 points each, with every row loaded.
    var resizeStepMs: Distribution
    /// Another one-page chat, opened once the conversation view has been
    /// built before: what opening costs without first-use setup.
    var openFirstPageWarm: Open
    var memoryFootprintMB: Double
    /// Up and back down fast, three times, after paging and with everything loaded.
    var pagingFlicks: Scroll
    var fullFlicks: Scroll
    /// The chat list (200 chats) down and back up at 3,000 pt/s.
    var sidebarScroll: Scroll
    var integrity: Integrity

    var summary: String {
        func ms(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
        func dist(_ d: Distribution) -> String {
            "p50 \(ms(d.p50))  p95 \(ms(d.p95))  p99 \(ms(d.p99))  max \(ms(d.max))"
        }
        func open(_ o: Open) -> String {
            "\(o.rows) rows: \(ms(o.wallMs)) ms wall, \(ms(o.mainThreadMs)) ms main thread"
        }
        func scroll(_ s: Scroll) -> String {
            """
            rows \(s.rowsAtStart) → \(s.rowsAtEnd), \(s.olderPagesLoaded) older pages, \
            \(s.frames) frames in \(ms(s.durationSeconds)) s at \(Int(s.speedPointsPerSecond)) pt/s, \
            \(ms(s.secondsAtTop)) s stuck at the top
                frame work       \(dist(s.frameWorkMs))
                frame interval   \(dist(s.frameIntervalMs))  (budget \(ms(s.frameBudgetMs)))
                hitches          \(s.hitches), \(ms(s.hitchTimeRatioMsPerSecond)) ms/s
            """
        }
        func events(_ e: EventCost) -> String {
            """
            \(e.rows) rows (idle baseline \(ms(e.baselineMs)) ms subtracted)
                presence elsewhere  \(dist(e.presenceElsewhereMs))
                message elsewhere   \(dist(e.messageElsewhereMs))
            """
        }
        return """
        ZapFast timeline benchmark: \(messageCount) messages on \(machine), \(system), \(configuration)
          Window \(windowSize), timeline \(Int(timelineWidth)) pt wide
          Open (first page)     \(open(openFirstPage))
          Events, first page    \(events(eventsWithFirstPage))
          Scroll with paging    \(scroll(pagingScroll))
          Open (full history)   \(open(openFullHistory))
          Scroll, full history  \(scroll(fullScroll))
          Jump to offset        \(dist(jumpToOffsetMs))
          Events, full history  \(events(eventsWithFullHistory))
          Resize step (8 pt)    \(dist(resizeStepMs))
          Open again (warm)     \(open(openFirstPageWarm))
          Memory footprint      \(ms(memoryFootprintMB)) MB
          Flicks, paged         \(scroll(pagingFlicks))
          Flicks, full history  \(scroll(fullFlicks))
          Chat list scroll      \(scroll(sidebarScroll))
          Integrity             \(integrity.checks) checks of \(integrity.rows) rows: \
        \(integrity.misplacedRows) misplaced, \(integrity.missingRows) missing
                bad checks       \(integrity.badChecks.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                kinds            \(integrity.kinds.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        """
    }
}
