import Foundation

/// How the table goes from one list of rows to the next.
nonisolated enum TimelineDiff: Equatable {
    /// Nothing to do.
    case none
    /// Too different to patch: reload the table.
    case reload
    /// The same rows in the same order; some changed in place (new indices).
    case update(changed: IndexSet)
    /// Rows left and arrived. `removed` are old indices, `inserted` new
    /// ones, `changed` new indices of rows that stayed but changed.
    case patch(removed: IndexSet, inserted: IndexSet, changed: IndexSet)

    /// More moved rows than this reload the table instead.
    static let patchLimit = 300

    static func between(
        _ old: [String],
        _ new: [String],
        changed isChanged: (_ old: Int, _ new: Int) -> Bool
    ) -> TimelineDiff {
        if old.isEmpty || new.isEmpty {
            return old.isEmpty && new.isEmpty ? .none : .reload
        }
        if old == new {
            let changed = IndexSet(new.indices.filter { isChanged($0, $0) })
            return changed.isEmpty ? .none : .update(changed: changed)
        }
        let difference = new.difference(from: old)
        guard difference.removals.count + difference.insertions.count <= patchLimit else { return .reload }
        var removed = IndexSet()
        var inserted = IndexSet()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Rows that stayed pair up in order, old with new.
        var changed = IndexSet()
        var oldIndex = 0
        for newIndex in new.indices where !inserted.contains(newIndex) {
            while removed.contains(oldIndex) { oldIndex += 1 }
            if isChanged(oldIndex, newIndex) { changed.insert(newIndex) }
            oldIndex += 1
        }
        return .patch(removed: removed, inserted: inserted, changed: changed)
    }
}
