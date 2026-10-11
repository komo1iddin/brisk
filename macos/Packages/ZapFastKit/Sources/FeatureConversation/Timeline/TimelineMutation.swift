import ZapFastCore

/// Validate the journal across every coalesced revision. Missing history
/// falls back to a complete diff; callers never guess which rows changed.
enum TimelineMutation {
    static func resolve(_ changes: [ConversationDelta], after revision: Int, through latest: Int,
                        previousCount: Int, count: Int) -> [Int]? {
        let relevant = changes.filter { $0.revision > revision && $0.revision <= latest }
        guard relevant.first?.revision == revision + 1, relevant.last?.revision == latest else { return nil }
        var expected = revision + 1
        var rows = previousCount
        var indexes: Set<Int> = []
        for change in relevant {
            guard change.revision == expected, change.previousCount == rows, change.count >= rows,
                  change.updated.allSatisfy({ $0 >= 0 && $0 < change.count }) else { return nil }
            indexes.formUnion(change.updated)
            rows = change.count
            expected += 1
        }
        guard rows == count else { return nil }
        return indexes.sorted()
    }
}
