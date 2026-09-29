import AppKit
import SwiftUI

/// An `NSSearchField` that hands the arrow keys, Return and Escape to its
/// owner, so the results beside it can be walked without leaving the field.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    /// Changing it puts the cursor in the field.
    var focusRequest: Int = 0
    var onSubmit: () -> Void = {}
    /// `true` for down, `false` for up.
    var onMove: (Bool) -> Void = { _ in }
    /// Escape in an empty field.
    var onEscape: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focused != focusRequest {
            context.coordinator.focused = focusRequest
            // The field has no window until it is on screen.
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        var focused: Int?

        init(_ parent: SearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(true)
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(false)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                if parent.text.isEmpty {
                    parent.onEscape()
                } else {
                    (control as? NSSearchField)?.stringValue = ""
                    parent.text = ""
                }
            default:
                return false
            }
            return true
        }
    }
}
