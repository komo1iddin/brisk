import Foundation

/// Protected by VideoRenderer's submission lock. Dropping an H.264 unit
/// invalidates the dependent chain, so overflow clears it and signals a gap.
nonisolated struct VideoFrameInbox {
    struct Frame { let data: Data; let keyframe: Bool; let orientation: UInt8 }
    struct Work { let stream: UInt64; let reset: Bool; let gap: Bool; let frame: Frame? }
    static let frameLimit = 8
    static let byteLimit = 4 * 1024 * 1024
    static let unitLimit = 1024 * 1024
    private(set) var frames: [Frame] = []
    private(set) var bytes = 0
    private(set) var stream: UInt64 = 0
    private var needsReset = false
    private var gap = false

    mutating func append(_ frame: Frame) {
        if frame.data.count > Self.unitLimit || frames.count >= Self.frameLimit || bytes + frame.data.count > Self.byteLimit {
            frames.removeAll(keepingCapacity: true)
            bytes = 0
            gap = true
        }
        guard frame.data.count <= Self.unitLimit else { return }
        frames.append(frame)
        bytes += frame.data.count
    }

    mutating func reset() {
        stream &+= 1
        frames.removeAll(keepingCapacity: true)
        bytes = 0
        needsReset = true
        gap = false
    }

    mutating func next() -> Work? {
        guard needsReset || gap || !frames.isEmpty else { return nil }
        let frame = frames.isEmpty ? nil : frames.removeFirst()
        if let frame { bytes -= frame.data.count }
        let work = Work(stream: stream, reset: needsReset, gap: gap, frame: frame)
        needsReset = false
        gap = false
        return work
    }
}

nonisolated struct VideoKeyframeRequests {
    private var last: ContinuousClock.Instant?
    mutating func shouldRequest(at now: ContinuousClock.Instant = .now) -> Bool {
        if let last, now - last < .seconds(1) { return false }
        last = now
        return true
    }
}
