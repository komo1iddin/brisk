import Foundation
import ZapFastBridge

/// Bounds retained records, independently of decoded media caches. Payload
/// accounting includes nested strings and binary fields, with headroom for
/// value storage. A single oversized message remains readable.
public struct HistoryBudget: Sendable {
    public static let standard = HistoryBudget(rows: 1_200, bytes: 16 * 1_024 * 1_024)
    public let rows: Int
    public let bytes: Int
    public init(rows: Int, bytes: Int) {
        self.rows = max(1, rows)
        self.bytes = max(1, bytes)
    }

    static func cost(_ value: Any) -> Int {
        if let string = value as? String { return 64 + string.utf8.count * 2 }
        if let data = value as? Data { return 64 + data.count }
        // Bridge records are finite value trees. Reflection is confined to
        // changed records at ingestion, never layout or scrolling.
        return 32 + Mirror(reflecting: value).children.reduce(0) { $0 + cost($1.value) }
    }
}
