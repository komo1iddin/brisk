import Foundation
import ZapFastBridge

/// A search hit's text for a one- or two-line row: the matched words in
/// bold, and a long message cut so the match is in view rather than past
/// the end of the line. Words match as the archive matched them (any case,
/// any of Uzbek's apostrophes, Latin or Cyrillic), through `searchMatchSpans`.
public enum SearchSnippet {
    /// Characters of context kept before a match that is far into the text.
    static let lead = 32

    public static func make(_ text: String, matching query: String) -> AttributedString {
        let flat = text.replacing(/\s+/, with: " ")
        let spans = SearchMarks.ranges(in: flat, matching: query)
        guard let first = spans.first else { return AttributedString(flat) }

        let firstStart = String.Index(utf16Offset: first.location, in: flat)
        var start = flat.startIndex
        if flat.distance(from: flat.startIndex, to: firstStart) > lead {
            start = flat.index(firstStart, offsetBy: -lead)
            // Start on a word, not inside one.
            if let space = flat[start..<firstStart].firstIndex(of: " ") {
                start = flat.index(after: space)
            }
        }
        let clipped = start != flat.startIndex
        let cut = flat.utf16.distance(from: flat.utf16.startIndex, to: start)
        let visible = String(flat[start...])
        var snippet = AttributedString(clipped ? "…" : "")
        let prefix = snippet.characters.count
        snippet += AttributedString(visible)

        // Every match in view is marked, not only the first.
        for span in spans where span.location >= cut {
            let from = String.Index(utf16Offset: span.location - cut, in: visible)
            let to = String.Index(utf16Offset: span.location - cut + span.length, in: visible)
            let lower = snippet.index(
                snippet.startIndex, offsetByCharacters: prefix + visible.distance(from: visible.startIndex, to: from)
            )
            let upper = snippet.index(lower, offsetByCharacters: visible.distance(from: from, to: to))
            snippet[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return snippet
    }
}

/// Where a search's words stand in a text, as the archive matches them.
public enum SearchMarks {
    /// UTF-16 ranges, in order, for `NSAttributedString` and `NSString`.
    public static func ranges(in text: String, matching query: String) -> [NSRange] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.isEmpty else { return [] }
        let length = (text as NSString).length
        return searchMatchSpans(text: text, query: query).compactMap { span in
            let range = NSRange(location: Int(span.start), length: Int(span.length))
            return NSMaxRange(range) <= length ? range : nil
        }
    }
}
