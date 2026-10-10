/// The message body as a real text view, so it can be selected, copied
/// and clicked.

import AppKit
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// The body as a real text view, for selecting, copying and clicking links.
/// TextKit 1 with no padding lays the string out exactly as the string
/// drawing that measured it. The footer's room at the end is never selected
/// or copied.
final class BodyTextView: NSTextView, NSTextViewDelegate {
    weak var cell: BubbleCell?
    private let visibleLength: Int

    init(layout: BubbleLayout, body: TextPiece) {
        visibleLength = layout.bodyLength
        let storage = NSTextStorage(attributedString: layout.linkedBody ?? body.string)
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: body.rect.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        super.init(frame: body.rect, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        isAutomaticLinkDetectionEnabled = false
        linkTextAttributes = [.foregroundColor: layout.linkColor, .cursor: NSCursor.pointingHand]
        if layout.fromMe {
            // The usual selection colour is the accent, which the bubble is.
            selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.35)]
        }
        delegate = self
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        visibleLength = 0
        super.init(frame: frameRect, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var selectedText: String? {
        let range = selectedRange()
        guard range.length > 0 else { return nil }
        return (string as NSString).substring(with: range)
    }

    override func selectionRange(forProposedRange proposedCharRange: NSRange, granularity: NSSelectionGranularity) -> NSRange {
        let range = super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
        let end = min(NSMaxRange(range), visibleLength)
        let start = min(range.location, end)
        return NSRange(location: start, length: end - start)
    }

    override func mouseDown(with event: NSEvent) {
        // ⌘-click selects messages, on the text as anywhere on the row.
        if event.modifierFlags.contains(.command), let cell {
            cell.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { cell?.delegate?.bodyTextBecameActive(self) }
        return accepted
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let cell, let id = cell.messageID else { return nil }
        return cell.delegate?.menu(forMessage: id, selection: selectedText)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url else { return false }
        cell?.delegate?.open(url)
        return true
    }
}
