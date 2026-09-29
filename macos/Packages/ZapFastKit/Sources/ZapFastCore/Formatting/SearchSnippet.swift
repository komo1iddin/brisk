import Foundation

/// A search hit's text for a one- or two-line row: the matched words in
/// bold, and a long message cut so the match is in view rather than past
/// the end of the line.
public enum SearchSnippet {
    /// Characters of context kept before a match that is far into the text.
    static let lead = 32

    public static func make(_ text: String, matching query: String) -> AttributedString {
        let flat = text.replacing(/\s+/, with: " ")
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard !needle.isEmpty, let match = flat.range(of: needle, options: options) else {
            return AttributedString(flat)
        }

        var start = flat.startIndex
        if flat.distance(from: flat.startIndex, to: match.lowerBound) > lead {
            start = flat.index(match.lowerBound, offsetBy: -lead)
            // Start on a word, not inside one.
            if let space = flat[start..<match.lowerBound].firstIndex(of: " ") {
                start = flat.index(after: space)
            }
        }
        let clipped = start != flat.startIndex
        var snippet = AttributedString(clipped ? "…" : "")
        snippet += AttributedString(flat[start...])

        // Every occurrence in view is marked, not only the first.
        let visible = String(flat[start...])
        var searchFrom = visible.startIndex
        let offset = clipped ? 1 : 0
        while let found = visible.range(of: needle, options: options, range: searchFrom..<visible.endIndex) {
            let lower = snippet.index(
                snippet.startIndex,
                offsetByCharacters: offset + visible.distance(from: visible.startIndex, to: found.lowerBound)
            )
            let upper = snippet.index(lower, offsetByCharacters: visible.distance(from: found.lowerBound, to: found.upperBound))
            snippet[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            searchFrom = found.upperBound
        }
        return snippet
    }
}
