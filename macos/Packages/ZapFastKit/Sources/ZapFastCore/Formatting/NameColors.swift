import Foundation

/// How WhatsApp colours names in a group: each current member gets a colour
/// of their own while there are colours enough, so two people in a chat
/// rarely share one, and one person's colour can differ between groups.
/// Someone no longer in the group keeps the colour their id leads to.
/// Indices into `AppKitPalette.name(_:)`.
public nonisolated enum NameColors {
    /// As many as `AppKitPalette.nameColorCount`.
    public static let count = 16

    /// Where an id starts looking for its colour.
    public static func hashed(_ id: String) -> Int {
        var hash: UInt64 = 5381
        for byte in id.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        return Int(hash % UInt64(count))
    }

    /// A colour for each member, by id order: each takes the colour its id
    /// leads to, or the next free one; past `count` members a new round
    /// starts.
    public static func assign(members: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        var taken = [Bool](repeating: false, count: count)
        for id in members.sorted() where result[id] == nil {
            if !taken.contains(false) { taken = [Bool](repeating: false, count: count) }
            var index = hashed(id)
            while taken[index] { index = (index + 1) % count }
            taken[index] = true
            result[id] = index
        }
        return result
    }
}
