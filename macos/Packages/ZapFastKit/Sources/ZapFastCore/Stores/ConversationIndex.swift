import ZapFastBridge

/// Owned only by the main-actor store. Passing this reference to a merge
/// does not share the dictionary storage with an argument value, so an
/// append can mutate it without copying the whole index.
final class ConversationIndex {
    private var positions: [String: Int]

    init(_ messages: [MessageRecord]) {
        positions = Dictionary(messages.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func index(_ id: String) -> Int? { positions[id] }
    func append(_ id: String, at index: Int) { positions[id] = index }
}
