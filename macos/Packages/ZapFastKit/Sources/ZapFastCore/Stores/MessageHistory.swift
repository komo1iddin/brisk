import ZapFastBridge

/// Value snapshots of loaded history. A live mutation copies one small
/// block instead of retaining/copying every message in a large chat.
nonisolated public struct MessageHistory: RandomAccessCollection, MutableCollection, ExpressibleByArrayLiteral, Equatable, Sendable {
    public typealias Index = Int
    public typealias Element = MessageRecord
    private static let blockSize = 256
    private var blocks: [[MessageRecord]] = []
    public private(set) var count = 0

    public init() {}
    public init(arrayLiteral elements: MessageRecord...) { self.init(elements) }

    public init(_ messages: some Sequence<MessageRecord>) {
        if let history = messages as? MessageHistory { self = history; return }
        for message in messages { append(message) }
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { count }
    public func index(after index: Int) -> Int { index + 1 }
    public func index(before index: Int) -> Int { index - 1 }

    public subscript(index: Int) -> MessageRecord {
        get {
            precondition(index >= 0 && index < count)
            return blocks[index / Self.blockSize][index % Self.blockSize]
        }
        set {
            precondition(index >= 0 && index < count)
            blocks[index / Self.blockSize][index % Self.blockSize] = newValue
        }
    }

    public mutating func append(_ message: MessageRecord) {
        if count.isMultiple(of: Self.blockSize) {
            var block = [MessageRecord]()
            block.reserveCapacity(Self.blockSize)
            block.append(message)
            blocks.append(block)
        } else {
            blocks[blocks.count - 1].append(message)
        }
        count += 1
    }

    public mutating func removeAll(where predicate: (MessageRecord) -> Bool) {
        self = MessageHistory(filter { !predicate($0) })
    }
}
