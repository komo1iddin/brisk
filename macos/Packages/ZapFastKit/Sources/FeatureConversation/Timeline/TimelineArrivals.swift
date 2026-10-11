/// Only unseen incoming rows after the previous message tail belong to
/// the newest-message badge. History inserted above it leaves the count.
enum TimelineArrivals {
    static func count(from old: [TimelineController.Item], to new: [TimelineController.Item]) -> Int {
        guard let tail = old.last(where: { $0.message != nil }), let message = tail.message else { return 0 }
        let known = Set(old.map(\.id))
        if let index = new.firstIndex(where: { $0.id == tail.id }) {
            return new[(index + 1)...].count { item in
                !known.contains(item.id) && item.message.map { !$0.fromMe } == true
            }
        }
        // If that tail was deleted in the same batch, only a strictly later
        // timestamp establishes a new arrival without an insertion anchor.
        return new.count { item in
            guard !known.contains(item.id), let after = item.message else { return false }
            return !after.fromMe && after.timestamp > message.timestamp
        }
    }
}
