import AppKit
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastSharedUI

// MARK: - Cell actions

extension TimelineController: TimelineCellDelegate {
    func showQuote(ofMessage id: String) {
        guard let model, let message = message(id) else { return }
        model.showQuoted(in: message)
    }

    func showSender(ofMessage id: String) {
        guard let model, let message = message(id) else { return }
        model.showInfo(in: message.chat, person: message.sender)
    }

    func menu(forMessage id: String, selection: String?) -> NSMenu? {
        guard let model, let message = message(id) else { return nil }
        let menu = NSHostingMenu(rootView: MessageActions(message: message, model: model))
        if let selection {
            let copy = NSMenuItem(title: String(localized: "Copy Selection"), action: #selector(copySelection(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = selection
            copy.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: nil)
            menu.insertItem(copy, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func copySelection(_ item: NSMenuItem) {
        guard let text = item.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func open(_ url: URL) {
        guard model?.openInviteLink(url) != true else { return }
        NSWorkspace.shared.open(url)
    }

    /// One message's text is selectable at a time, as before: another's
    /// text view goes unless it holds a selection.
    func bodyHovered(in cell: TextBubbleCell) {
        forEachTextCell { other in
            guard other !== cell, let text = other.bodyText, text.selectedRange().length == 0 else { return }
            other.removeBodyText()
        }
        _ = cell.installBodyText()
    }

    func bodyTextBecameActive(_ view: BodyTextView) {
        forEachTextCell { other in
            if let text = other.bodyText, text !== view { other.removeBodyText() }
        }
    }

    /// ⌘-click starts selecting messages, as the SwiftUI rows' does.
    func startSelecting(fromMessage id: String) {
        guard let model, let message = message(id), model.canSelect(message) else { return }
        model.select(message)
    }

    /// Reply and React beside the bubble under the pointer, the SwiftUI
    /// rows' own view, made only while the pointer is there.
    func hoverActions(forMessage id: String) -> NSView? {
        guard let model, let message = message(id) else { return nil }
        let view = NSHostingView(rootView: HoverActions(message: message, model: model)
            .environment(\.chatTheme, style.theme))
        view.sizingOptions = []
        view.frame.size = view.fittingSize
        return view
    }

    func isPickingReaction(forMessage id: String) -> Bool {
        guard let model, let chatID else { return false }
        return model.reactionTarget == MessageKey(chat: chatID, message: id)
    }

    /// The reaction picker hangs from the bubble, as the SwiftUI rows' does.
    func reactionPicker(forMessage id: String) -> NSViewController? {
        guard let model, let message = message(id) else { return nil }
        return NSHostingController(rootView: ReactionPicker(
            quick: model.quickReactions(for: message),
            mine: message.reactions.first(where: \.fromMe)?.emoji,
            frequent: model.preferences.reactionEmoji.map(\.emoji)
        ) { model.react($0, to: message) })
    }

    func reactionPickerClosed(forMessage id: String) {
        guard let model, let chatID, model.reactionTarget == MessageKey(chat: chatID, message: id) else { return }
        model.reactionTarget = nil
    }

    /// What the pointer finds beside the bubble, as actions for VoiceOver.
    func accessibilityActions(forMessage id: String) -> [NSAccessibilityCustomAction] {
        guard let model, let message = message(id) else { return [] }
        var actions = [
            NSAccessibilityCustomAction(name: String(localized: "Reply")) { model.reply(to: message); return true },
            NSAccessibilityCustomAction(name: String(localized: "React")) { model.showReactionPicker(for: message); return true },
        ]
        if model.canSelect(message) {
            actions.append(NSAccessibilityCustomAction(name: String(localized: "Select")) { model.select(message); return true })
        }
        return actions
    }
}
