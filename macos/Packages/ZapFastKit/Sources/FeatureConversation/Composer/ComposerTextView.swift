import AppKit
import SwiftUI

/// The message field: a real `NSTextView`, so input methods, spelling,
/// dictation, Writing Tools, and Services all work. Return sends;
/// Shift- or Option-Return starts a new line. It grows with its text up to
/// `maxHeight`, then scrolls.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    /// Changing this moves keyboard focus into the field (a new chat opened).
    let focusToken: String
    let maxHeight: CGFloat
    let onSubmit: () -> Void
    let onEdit: () -> Void
    let onPasteFiles: ([URL]) -> Void
    /// A picture pasted without a file (a screenshot, a copied image).
    var onPasteImage: (CGImage) -> Void = { _ in }
    /// Up Arrow in an empty field; returns whether it was used.
    var onUpInEmpty: () -> Bool = { false }
    /// Follows `@` queries and takes the keys while suggestions show.
    var mentions: MentionTracker?
    /// Follows `:shortcode` queries the same way.
    var emoji: EmojiTracker?
    /// Picked `@name`s, drawn in the accent colour.
    var mentionNames: [String] = []

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        // Shown only once the text outgrows the field; see `measure()`.
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = ComposerNSTextView()
        textView.onPasteFiles = onPasteFiles
        textView.onPasteImage = onPasteImage
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.setAccessibilityLabel(String(localized: "Message"))
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        mentions?.textView = textView
        emoji?.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            mentions?.cancel()
            emoji?.cancel()
            context.coordinator.measure()
        }
        mentions?.textView = textView
        emoji?.textView = textView
        context.coordinator.highlightMentions()
        if context.coordinator.focusedToken != focusToken {
            context.coordinator.focusedToken = focusToken
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var focusedToken: String?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            parent.onEdit()
            // A `:` starting a shortcode ends a mention, as upstream's does.
            if parent.emoji?.textChanged(in: textView) == true { parent.mentions?.cancel() }
            parent.mentions?.textChanged(in: textView)
            if parent.mentions?.query != nil { parent.emoji?.cancel() }
            measure()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            parent.mentions?.selectionChanged(in: textView)
            parent.emoji?.selectionChanged(in: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if !textView.hasMarkedText(),
               parent.emoji?.handle(selector) == true || parent.mentions?.handle(selector) == true {
                return true
            }
            if selector == #selector(NSResponder.moveUp(_:)), textView.string.isEmpty {
                return parent.onUpInEmpty()
            }
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else if !textView.hasMarkedText() {
                parent.onSubmit()
            } else {
                return false
            }
            return true
        }

        /// Colours each picked `@name` still in the text. Temporary
        /// attributes stay out of the text itself, which remains plain.
        func highlightMentions() {
            guard let textView, let layout = textView.layoutManager else { return }
            let text = textView.string as NSString
            let whole = NSRange(location: 0, length: text.length)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
            for name in Set(parent.mentionNames) {
                var searched = whole
                while searched.length > 0 {
                    let found = text.range(of: "@\(name)", options: [], range: searched)
                    guard found.location != NSNotFound else { break }
                    layout.addTemporaryAttribute(.foregroundColor, value: NSColor.controlAccentColor, forCharacterRange: found)
                    let next = found.location + found.length
                    searched = NSRange(location: next, length: text.length - next)
                }
            }
        }

        func measure() {
            guard let textView, let container = textView.textContainer,
                  let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + textView.textContainerInset.height * 2
            let line = (textView.font?.boundingRectForFont.height ?? 17) + textView.textContainerInset.height * 2
            let height = min(parent.maxHeight, max(line, ceil(used)))
            scrollView?.hasVerticalScroller = used > parent.maxHeight
            if abs(height - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = height }
            }
        }
    }
}

/// Pasting files (a Finder copy) attaches them instead of pasting their
/// names, and a copied picture is attached as an image; text pastes plain.
private final class ComposerNSTextView: NSTextView {
    var onPasteFiles: ([URL]) -> Void = { _ in }
    var onPasteImage: (CGImage) -> Void = { _ in }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onPasteFiles(urls)
            return
        }
        // Text wins over a picture a rich copy also carries (a web page).
        let hasText = board.availableType(from: [.string]) != nil
        if !hasText, let image = NSImage(pasteboard: board),
           let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            onPasteImage(picture)
            return
        }
        pasteAsPlainText(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), NSImage.canInit(with: NSPasteboard.general) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }
}
