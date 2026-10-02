import Foundation
import Observation
import ZapFastBridge

/// Getting a chat's files and older messages from the phone, on purpose.
///
/// Files come one at a time as they scroll into view, and only once: a chat
/// the person has not scrolled through has none of its files here, and one
/// whose files WhatsApp's servers no longer hold needs the phone to upload
/// them again. Older messages come from the phone fifty at a time, only when
/// the timeline reaches its top. This runs both for a whole chat: the files
/// newest first, a few at a time, and the history request after request,
/// stopping when the phone has nothing more or does not answer.

/// The kinds of files the person picks between.
public enum FetchGroup: CaseIterable, Sendable {
    case photos, videos, audio, files

    init(_ kind: ChatMediaKind) {
        switch kind {
        case .photo: self = .photos
        case .video: self = .videos
        case .voice, .audio: self = .audio
        case .document: self = .files
        }
    }
}

/// Why a job stopped before it was done, and waits for the person or for the
/// connection.
public enum FetchPause: Equatable, Sendable {
    /// The phone did not answer several requests in a row.
    case phoneSilent
    /// This Mac is not connected to WhatsApp.
    case offline
}

/// The files still to fetch, which ones are on their way, and how the others
/// fared. Pure bookkeeping: `PhoneFetch` sends the downloads.
struct MediaQueue: Equatable {
    struct Item: Equatable, Sendable {
        let message: String
        let size: UInt64
    }

    /// Downloads on their way at once.
    static let width = 3
    /// Answers in a row from a silent phone before the queue waits for the
    /// person: asking on would only stack requests the phone cannot answer.
    static let silentLimit = 3
    /// Tries a file that failed for no clear reason gets.
    static let tries = 2

    private(set) var waiting: [Item]
    private(set) var running: [String: Item] = [:]
    /// Files whose request the phone did not answer, or could not fulfil:
    /// they wait for the person to try again.
    private(set) var held: [Item] = []
    private var retry: [Item] = []
    private var tried: [String: Int] = [:]
    private var silentStreak = 0
    private(set) var pause: FetchPause?

    /// How many were asked for.
    let total: Int
    private(set) var done = 0
    private(set) var gone = 0
    private(set) var failed = 0
    /// Files larger than the limit, left out from the start.
    let skippedLarge: Int

    init(items: [Item], limit: UInt64) {
        let (fit, large) = (items.filter { $0.size <= limit }, items.filter { $0.size > limit })
        waiting = fit
        total = fit.count
        skippedLarge = large.count
    }

    /// Settled: fetched, gone, or given up on.
    var settled: Int { done + gone + failed }

    /// Nothing is on its way and nothing will be started without the person.
    var isOver: Bool {
        running.isEmpty && (pause != nil || (waiting.isEmpty && retry.isEmpty))
    }

    /// The files to start now, up to the width, none while paused.
    mutating func take() -> [Item] {
        guard pause == nil else { return [] }
        if waiting.isEmpty, running.isEmpty, !retry.isEmpty { (waiting, retry) = (retry, []) }
        var started: [Item] = []
        while running.count < Self.width, !waiting.isEmpty {
            let item = waiting.removeFirst()
            running[item.message] = item
            started.append(item)
        }
        return started
    }

    /// A file settled. Ignores one that is not on its way.
    mutating func finish(_ message: String, failure: DownloadFailure?) {
        guard let item = running.removeValue(forKey: message) else { return }
        guard let failure else {
            done += 1
            silentStreak = 0
            return
        }
        switch failure {
        case .gone:
            gone += 1
            silentStreak = 0
        case .tooLarge:
            failed += 1
        case .phoneSilent:
            held.append(item)
            silentStreak += 1
            if silentStreak >= Self.silentLimit { pause = .phoneSilent }
        case .phoneRefused:
            held.append(item)
            silentStreak = 0
        case .offline:
            held.append(item)
            pause = .offline
        case .timedOut, .other:
            tried[message, default: 0] += 1
            if tried[message, default: 0] < Self.tries {
                retry.append(item)
            } else {
                failed += 1
            }
        }
    }

    /// The person asked to go on, or the connection is back: the files the
    /// phone left unanswered go first.
    mutating func resume() {
        pause = nil
        silentStreak = 0
        waiting = held + waiting
        held = []
    }

    /// The person stopped: nothing more is started.
    mutating func stop() {
        waiting = []
        retry = []
    }
}

/// How a run of requests for older messages stands.
public enum FetchHistoryState: Equatable, Sendable {
    case asking
    /// The phone has nothing older.
    case exhausted
    /// The phone did not answer, twice in a row.
    case silent
    /// This Mac was not connected to WhatsApp.
    case offline
    case stopped
}

/// A run of requests for older messages: each answer decides whether to ask
/// again.
struct HistoryRun: Equatable {
    typealias State = FetchHistoryState

    /// Answers in a row that brought nothing before the phone counts as silent.
    static let drySpell = 2

    private(set) var state = State.asking
    /// Messages brought so far.
    private(set) var loaded = 0
    private var arrived = 0
    private var dry = 0

    var isOver: Bool { state != .asking }

    mutating func arrived(_ count: Int) {
        guard state == .asking else { return }
        arrived += count
    }

    /// The phone answered a request, or the backend gave up waiting for it.
    /// Whether to ask again.
    mutating func answered(more: Bool) -> Bool {
        guard state == .asking else { return false }
        loaded += arrived
        let gained = arrived
        arrived = 0
        guard more else {
            state = .exhausted
            return false
        }
        if gained > 0 {
            dry = 0
            return true
        }
        dry += 1
        if dry >= Self.drySpell {
            state = .silent
            return false
        }
        return true
    }

    mutating func end(_ state: State) {
        if self.state == .asking { self.state = state }
    }
}

/// What the sheet shows and does for one chat.
@MainActor
@Observable
public final class PhoneFetch {
    /// How a chat's files stand.
    public struct Counts: Equatable, Sendable {
        public var total = 0
        /// Not on this Mac, and within what can be downloaded.
        public var missing = 0
        public var missingBytes: UInt64 = 0
        /// Not on this Mac, and over the size limit.
        public var tooLarge = 0
        /// Not on this Mac, and the phone has said it no longer has them.
        public var unavailable = 0

        public init(
            total: Int = 0, missing: Int = 0, missingBytes: UInt64 = 0, tooLarge: Int = 0, unavailable: Int = 0
        ) {
            self.total = total
            self.missing = missing
            self.missingBytes = missingBytes
            self.tooLarge = tooLarge
            self.unavailable = unavailable
        }
    }

    /// What the sheet needs from the app.
    struct Hooks {
        var openReader: () async throws -> any ChatReaderProtocol
        var download: (String) -> Void
        var askOlder: () -> Void
        var isConnected: () -> Bool
        var finished: (String) -> Void = { _ in }
        var gone: GoneMedia
    }

    public enum Phase: Equatable {
        case counting
        case ready
        case failed(String)
    }

    public let chat: String
    public private(set) var phase = Phase.counting
    public private(set) var messages = 0
    public private(set) var oldest: Date?
    public private(set) var counts: [FetchGroup: Counts] = [:]
    /// Which kinds of files to fetch.
    public var selected = Set(FetchGroup.allCases)

    private(set) var queue: MediaQueue?
    private(set) var run: HistoryRun?

    @ObservationIgnored private let hooks: Hooks
    @ObservationIgnored private var items: [ChatMedia] = []
    @ObservationIgnored private var counting: Task<Void, Never>?

    init(chat: String, hooks: Hooks) {
        self.chat = chat
        self.hooks = hooks
        count()
    }

    /// A job is under way. One that waits for the person is not.
    public var isRunning: Bool {
        (queue.map { !$0.isOver } ?? false) || run?.state == .asking
    }

    // MARK: What the sheet reads

    /// How the file job stands.
    public struct FileProgress: Equatable, Sendable {
        public var total: Int
        public var done: Int
        public var gone: Int
        public var failed: Int
        /// Files the phone did not answer for, waiting to be asked again.
        public var held: Int
        public var skippedLarge: Int
        /// Downloads are on their way.
        public var running: Bool
        public var pause: FetchPause?

        public var settled: Int { done + gone + failed }
        public var isOver: Bool { !running }
    }

    public var files: FileProgress? {
        guard let queue else { return nil }
        return FileProgress(
            total: queue.total, done: queue.done, gone: queue.gone, failed: queue.failed,
            held: queue.held.count, skippedLarge: queue.skippedLarge,
            running: !queue.isOver, pause: queue.pause
        )
    }

    /// How the request for older messages stands, and how many it brought.
    public var history: (loaded: Int, state: FetchHistoryState)? {
        run.map { ($0.loaded, $0.state) }
    }

    // MARK: The count

    /// Reads the chat's archive, off the main actor.
    func count() {
        counting?.cancel()
        counting = Task { [hooks, chat] in
            do {
                let reader = try await hooks.openReader()
                let census = try await Self.census(of: chat, reader)
                guard !Task.isCancelled else { return }
                apply(census)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    @concurrent
    private static func census(of chat: String, _ reader: any ChatReaderProtocol) async throws -> ChatCensus {
        try reader.census(chat: chat)
    }

    private func apply(_ census: ChatCensus) {
        messages = Int(census.messages)
        oldest = census.oldest.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        items = census.media
        var counts: [FetchGroup: Counts] = [:]
        for item in census.media {
            let group = FetchGroup(item.kind)
            counts[group, default: Counts()].total += 1
            guard !item.here else { continue }
            if hooks.gone.contains(chat: chat, message: item.message) {
                counts[group, default: Counts()].unavailable += 1
            } else if item.size > AppModel.downloadLimit {
                counts[group, default: Counts()].tooLarge += 1
            } else {
                counts[group, default: Counts()].missing += 1
                counts[group, default: Counts()].missingBytes += item.size
            }
        }
        self.counts = counts
        phase = .ready
    }

    /// Files that would be fetched now: the chosen kinds, not here, not too large.
    public var wanted: Int { selected.reduce(0) { $0 + (counts[$1]?.missing ?? 0) } }
    public var wantedBytes: UInt64 { selected.reduce(0) { $0 + (counts[$1]?.missingBytes ?? 0) } }

    // MARK: Files

    public func startFiles() {
        guard phase == .ready, queue.map(\.isOver) ?? true else { return }
        finishedFiles = false
        let chosen = items.filter {
            !$0.here && selected.contains(FetchGroup($0.kind)) && !hooks.gone.contains(chat: chat, message: $0.message)
        }
        queue = MediaQueue(
            items: chosen.map { .init(message: $0.message, size: $0.size) },
            limit: AppModel.downloadLimit
        )
        pump()
    }

    public func stopFiles() {
        queue?.stop()
        settleFiles()
    }

    public func resumeFiles() {
        guard queue?.pause != nil || !(queue?.held.isEmpty ?? true) else { return }
        finishedFiles = false
        queue?.resume()
        pump()
    }

    /// A download the queue started has ended.
    func fileFinished(message: String, error: String?) {
        guard queue != nil else { return }
        let failure = error.map(DownloadFailure.init)
        if failure == .gone, queue?.running[message] != nil { hooks.gone.insert(chat: chat, message: message) }
        queue?.finish(message, failure: failure)
        pump()
    }

    private func pump() {
        guard var queue else { return }
        if queue.pause == .offline, hooks.isConnected() { queue.resume() }
        let started = queue.take()
        self.queue = queue
        for item in started { hooks.download(item.message) }
        settleFiles()
    }

    /// When the queue is over, count again (what came is here now) and tell
    /// the app how it went.
    private func settleFiles() {
        guard let queue, queue.isOver, queue.pause == nil, !finishedFiles else { return }
        finishedFiles = true
        hooks.finished(summary(of: queue))
        count()
    }

    @ObservationIgnored private var finishedFiles = false

    // MARK: Older messages

    public func startHistory() {
        guard run.map(\.isOver) ?? true else { return }
        run = HistoryRun()
        askOlder()
    }

    public func stopHistory() {
        run?.end(.stopped)
        count()
    }

    private func askOlder() {
        guard hooks.isConnected() else {
            run?.end(.offline)
            return
        }
        hooks.askOlder()
    }

    /// Older messages of this chat arrived.
    func olderArrived(count: Int) {
        run?.arrived(count)
    }

    /// The phone answered the request, or the backend gave up waiting.
    func olderAnswered(more: Bool) {
        guard run?.answered(more: more) == true else {
            if run?.isOver == true { count() }
            return
        }
        askOlder()
    }

    /// The connection came back: what waited for it goes on.
    func linkConnected() {
        if queue?.pause == .offline { pump() }
    }

    // MARK: Words

    /// How a finished file job went, as a sentence for the notice.
    func summary(of queue: MediaQueue) -> String {
        var parts = [String(localized: "Downloaded \(queue.done) of \(queue.total) files.")]
        if queue.gone > 0 { parts.append(String(localized: "\(queue.gone) are no longer available.")) }
        if !queue.held.isEmpty { parts.append(String(localized: "Your phone did not answer for \(queue.held.count).")) }
        if queue.failed > 0 { parts.append(String(localized: "\(queue.failed) could not be downloaded.")) }
        return parts.joined(separator: " ")
    }
}
