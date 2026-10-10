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

/// A borderless text field for a bar that draws its own capsule: no bezel,
/// no focus ring. Like `SearchField` it hands the keys that walk results to
/// its owner, and tells Return from Shift-Return and an empty field's
/// Delete, which takes the last filter off.
struct BareSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    /// Changing it puts the cursor in the field.
    var focusRequest: Int = 0
    /// `true` with Shift held.
    var onSubmit: (Bool) -> Void = { _ in }
    /// `true` for down, `false` for up.
    var onMove: (Bool) -> Void = { _ in }
    var onEscape: () -> Void = {}
    /// Delete with nothing before the cursor.
    var onDeleteAtStart: () -> Void = {}

    func makeCoordinator() -> SearchFieldCoordinator {
        SearchFieldCoordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != prompt { field.placeholderString = prompt }
        if context.coordinator.focused != focusRequest {
            context.coordinator.focused = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    final class SearchFieldCoordinator: NSObject, NSTextFieldDelegate {
        var parent: BareSearchField
        var focused: Int?

        init(_ parent: BareSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(true)
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(false)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
            case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.onSubmit(true)
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
            case #selector(NSResponder.deleteBackward(_:)):
                let range = textView.selectedRange()
                guard range.location == 0, range.length == 0 else { return false }
                parent.onDeleteAtStart()
            default:
                return false
            }
            return true
        }
    }
}
