import AppKit
import Observation
import ZapFastBridge

/// Follows a `:shortcode` typed in the composer (upstream's `active_emoji`):
/// a standalone `:` starts it, and anything but letters, digits, `_`, `-`
/// and `+` ends it without changing what was typed. Picking an emoji
/// replaces the `:query` with it, where Undo can take it back.
@Observable
final class EmojiTracker {
    /// UTF-16 offset of the `:`.
    private(set) var start: Int?
    private(set) var query: String?
    var selected = 0

    @ObservationIgnored weak var textView: NSTextView?
    @ObservationIgnored var candidates: (String) -> [EmojiSuggestionInfo] = { _ in [] }
    @ObservationIgnored var onPick: (String) -> Void = { _ in }

    var suggestions: [EmojiSuggestionInfo] {
        query.map(candidates) ?? []
    }

    /// Returns whether a `:` just typed started a query.
    @discardableResult
    func textChanged(in textView: NSTextView) -> Bool {
        let text = textView.string as NSString
        let cursor = textView.selectedRange().location
        var started = false
        if cursor > 0, text.character(at: cursor - 1) == UInt16(UInt8(ascii: ":")),
           Self.isStandalone(at: cursor - 1, in: text) {
            start = cursor - 1
            selected = 0
            started = true
        }
        revalidate(textView)
        return started && start != nil
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

    func pick(_ suggestion: EmojiSuggestionInfo) {
        guard let textView, let start else { return }
        let cursor = textView.selectedRange().location
        guard cursor > start else { return cancel() }
        let range = NSRange(location: start, length: cursor - start)
        cancel()
        onPick(suggestion.emoji)
        textView.insertText(suggestion.emoji, replacementRange: range)
    }

    private func revalidate(_ textView: NSTextView) {
        guard let start else { return }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        guard start < text.length, text.character(at: start) == UInt16(UInt8(ascii: ":")),
              selection.length == 0, selection.location > start else { return cancel() }
        let typed = text.substring(with: NSRange(location: start + 1, length: selection.location - start - 1))
        guard Self.isQuery(typed) else { return cancel() }
        if typed != query { selected = 0 }
        query = typed
    }

    static func isQuery(_ typed: String) -> Bool {
        typed.allSatisfy { $0.isLetter || $0.isNumber || "_-+".contains($0) }
    }

    /// Upstream's `standalone_trigger`: at the start, or after something
    /// that is not a letter or digit (so `10:30` does not trigger).
    private static func isStandalone(at index: Int, in text: NSString) -> Bool {
        guard index > 0 else { return true }
        let before = text.substring(with: text.rangeOfComposedCharacterSequence(at: index - 1))
        return !before.contains { $0.isLetter || $0.isNumber }
    }
}
