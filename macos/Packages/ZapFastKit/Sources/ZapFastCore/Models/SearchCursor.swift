/// Where the arrow keys have reached in the sidebar's chat results while the
/// search field has the keyboard (upstream's `search_selected`). The chat is
/// only marked, not opened, so walking past chats does not read them.
public nonisolated enum SearchCursor {
    /// The result after a ↓ or ↑ from `current`. ↓ goes to the next one, from
    /// none to the first, and stops at the last; ↑ goes to the previous one
    /// and, from none, stays on none.
    public static func moved(from current: String?, in ids: [String], down: Bool) -> String? {
        guard !ids.isEmpty else { return nil }
        let index = current.flatMap { ids.firstIndex(of: $0) }
        if down {
            return ids[index.map { min($0 + 1, ids.count - 1) } ?? 0]
        }
        return index.map { ids[max($0 - 1, 0)] }
    }

    /// The chat Enter opens: the one reached, else the first result.
    public static func opened(from current: String?, in ids: [String]) -> String? {
        if let current, ids.contains(current) { return current }
        return ids.first
    }
}
