import AppKit
import Observation
import ZapFastCore

/// Follows an `@` typed in the composer (upstream's `mention_start`): the
/// query runs from it to the cursor until the cursor leaves, or a newline
/// or another `@` enters. Picking a member replaces the query with
/// `@name ` in the text view, where Undo can take it back.
@Observable
final class MentionTracker {
    /// UTF-16 offset of the `@`.
    private(set) var start: Int?
    /// What follows the `@`, up to the cursor.
    private(set) var query: String?
    /// The highlighted suggestion.
    var selected = 0

    @ObservationIgnored weak var textView: NSTextView?
    @ObservationIgnored var candidates: (String) -> [MentionCandidate] = { _ in [] }
    @ObservationIgnored var onPick: (MentionCandidate) -> Void = { _ in }

    /// The members to offer now; empty hides the list.
    var suggestions: [MentionCandidate] {
        query.map(candidates) ?? []
    }

    /// The text changed by typing: a standalone `@` just before the cursor
    /// starts a query, anything else revalidates the one running.
    func textChanged(in textView: NSTextView) {
        let text = textView.string as NSString
        let cursor = textView.selectedRange().location
        if cursor > 0, text.character(at: cursor - 1) == UInt16(UInt8(ascii: "@")),
           Self.isStandalone(at: cursor - 1, in: text) {
            start = cursor - 1
            selected = 0
        }
        revalidate(textView)
    }

    func selectionChanged(in textView: NSTextView) {
        revalidate(textView)
    }

    func cancel() {
        start = nil
        query = nil
        selected = 0
    }

    /// Keys typed while the list shows: arrows move, Return and Tab pick,
    /// Escape closes. Returns whether the key was used.
    func handle(_ selector: Selector) -> Bool {
        let list = suggestions
        guard !list.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            selected = (selected + 1) % list.count
        case #selector(NSResponder.moveUp(_:)):
            selected = (selected + list.count - 1) % list.count
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            pick(list[min(selected, list.count - 1)])
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
            cancel()
        default:
            return false
        }
        return true
    }

    func pick(_ candidate: MentionCandidate) {
        guard let textView, let start else { return }
        let cursor = textView.selectedRange().location
        guard cursor > start else { return cancel() }
        let range = NSRange(location: start, length: cursor - start)
        cancel()
        onPick(candidate)
        textView.insertText("@\(candidate.name) ", replacementRange: range)
    }

    private func revalidate(_ textView: NSTextView) {
        guard let start else { return }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        guard start < text.length, text.character(at: start) == UInt16(UInt8(ascii: "@")),
              selection.length == 0, selection.location > start else { return cancel() }
        let typed = text.substring(with: NSRange(location: start + 1, length: selection.location - start - 1))
        guard !typed.contains("@"), !typed.contains("\n") else { return cancel() }
        if typed != query { selected = 0 }
        query = typed
    }

    /// Upstream's `standalone_trigger`: at the start, or after something
    /// that is not a letter or digit (so `mail@example` does not trigger).
    private static func isStandalone(at index: Int, in text: NSString) -> Bool {
        guard index > 0 else { return true }
        let before = text.substring(with: text.rangeOfComposedCharacterSequence(at: index - 1))
        return !before.contains { $0.isLetter || $0.isNumber }
    }
}
