import Foundation
import Observation
import ZapFastBridge

/// Each chat's calls, for its timeline: read from the bridge's encrypted
/// call history the first time the chat asks, then kept current by what the
/// bridge reports (calls the phone syncs, and calls rung or placed here).
@Observable
public final class CallHistory {
    /// Bumped per chat when its calls change, so a timeline reading one chat
    /// is not told about another.
    private var revisions: [String: Int] = [:]
    @ObservationIgnored private var loaded: [String: [CallLogEntry]] = [:]
    @ObservationIgnored private let read: (String) async -> [CallLogEntry]
    @ObservationIgnored private var loads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = UUID()

    init(read: @escaping (String) async -> [CallLogEntry]) {
        self.read = read
    }

    /// The chat's calls, oldest first.
    public func calls(in chat: String) -> [CallLogEntry] {
        _ = revisions[chat]
        if let calls = loaded[chat] { return calls }
        loaded[chat] = []
        let generation = generation
        let read = read
        loads[chat] = Task { [weak self] in
            let disk = await read(chat)
            guard !Task.isCancelled, let self, generation == self.generation else { return }
            // Reports received during the read are newer than its snapshot.
            var merged = Dictionary(disk.map { ($0.callId, $0) }, uniquingKeysWith: { _, last in last })
            for entry in self.loaded[chat] ?? [] { merged[entry.callId] = entry }
            self.loaded[chat] = merged.values.sorted {
                $0.timestamp != $1.timestamp ? $0.timestamp < $1.timestamp : $0.callId < $1.callId
            }
            self.loads[chat] = nil
            self.revisions[chat, default: 0] += 1
        }
        return []
    }

    func cancelLoads() {
        generation = UUID()
        for (chat, task) in loads { task.cancel(); loaded[chat] = nil }
        loads.removeAll()
    }

    func clear() {
        let chats = Set(loaded.keys).union(loads.keys)
        cancelLoads()
        loaded.removeAll()
        for chat in chats { revisions[chat, default: 0] += 1 }
    }

    /// A call was filed or changed.
    func add(_ entry: CallLogEntry) {
        // A chat never read reads it with the rest when it is opened.
        guard var calls = loaded[entry.chat] else { return }
        calls.removeAll { $0.callId == entry.callId }
        let place = calls.firstIndex { $0.timestamp > entry.timestamp } ?? calls.endIndex
        calls.insert(entry, at: place)
        loaded[entry.chat] = calls
        revisions[entry.chat, default: 0] += 1
    }
}

/// How a call reads in a chat: "Missed voice call · 14:05".
public enum CallText {
    public static func title(_ entry: CallLogEntry) -> String {
        let video = entry.video
        let what: String = switch entry.outcome {
        case .connected:
            video
                ? String(localized: "Video call · \(duration(entry.duration))")
                : String(localized: "Voice call · \(duration(entry.duration))")
        case .missed:
            video ? String(localized: "Missed video call") : String(localized: "Missed voice call")
        case .declined:
            video ? String(localized: "Video call declined") : String(localized: "Voice call declined")
        case .noAnswer:
            video ? String(localized: "Video call, no answer") : String(localized: "Voice call, no answer")
        case .cancelled:
            video ? String(localized: "Cancelled video call") : String(localized: "Cancelled voice call")
        case .answeredElsewhere:
            String(localized: "Answered on another device")
        case .failed:
            video ? String(localized: "Video call failed") : String(localized: "Voice call failed")
        }
        return "\(what) · \(DateText.bubble(entry.timestamp))"
    }

    /// "45 sec", "2 min", "1 hr 5 min".
    static func duration(_ seconds: UInt32) -> String {
        let value = Duration.seconds(Int64(seconds))
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds < 60 ? [.seconds] : [.hours, .minutes]
        return value.formatted(.units(allowed: units, width: .abbreviated))
    }
}
